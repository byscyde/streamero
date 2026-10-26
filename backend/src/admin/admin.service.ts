import { Inject, Injectable } from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { albumFrom, albumSelect, artistSelect, presentAlbum, presentArtist, presentTrack, presentVideo, trackFrom, trackSelect, videoFrom, videoSelect } from '../catalog/presenters.js';
import { badRequest, conflict, notFound } from '../common/errors.js';
import { toPage, type PageQuery } from '../common/pagination.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService, type Queryable } from '../db/db.service.js';
import { AuthService } from '../auth/auth.service.js';
import type { Role } from '../common/auth-user.js';
import { UsersService } from '../users/users.service.js';
import { AssetsService } from '../media/assets.service.js';
import { MediaProcessor } from '../ingestion/processor.js';
import { JobsService } from '../ingestion/jobs.service.js';
import { RedisService } from '../redis/redis.module.js';
import { STORAGE } from '../storage/storage.module.js';
import type { StorageDriver } from '../storage/storage.driver.js';

export interface TrackPatch {
  title?: string;
  artistName?: string;
  albumId?: string | null;
  trackNumber?: number | null;
  discNumber?: number;
  explicit?: boolean;
  genres?: string[];
  moods?: string[];
  downloadable?: boolean;
  isrc?: string | null;
}

@Injectable()
export class AdminService {
  constructor(
    private readonly db: DbService,
    private readonly audit: AuditService,
    private readonly assets: AssetsService,
    private readonly jobs: JobsService,
    private readonly processor: MediaProcessor,
    private readonly redis: RedisService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
    private readonly auth: AuthService,
    private readonly usersService: UsersService,
  ) {}

  async overview() {
    const [counts, plays, storage, jobs] = await Promise.all([
      this.db.one(`SELECT
        (SELECT count(*)::int FROM tracks) AS tracks,
        (SELECT count(*)::int FROM tracks WHERE status = 'ready') AS "readyTracks",
        (SELECT count(*)::int FROM albums) AS albums,
        (SELECT count(*)::int FROM artists) AS artists,
        (SELECT count(*)::int FROM videos) AS videos,
        (SELECT count(*)::int FROM playlists) AS playlists,
        (SELECT count(*)::int FROM users) AS users,
        (SELECT count(DISTINCT user_id)::int FROM playback_events WHERE played_at > now() - interval '7 days') AS "activeUsers7d"`),
      this.db.one(`SELECT
        (SELECT count(*)::int FROM playback_events WHERE played_at > now() - interval '24 hours') AS "plays24h",
        (SELECT count(*)::int FROM playback_events WHERE played_at > now() - interval '7 days') AS "plays7d"`),
      this.storageUsage(),
      this.jobs.stats(),
    ]);
    return { counts, plays, storage, jobs };
  }

  async storageUsage() {
    const rows = await this.db.query(`SELECT kind, count(*)::int AS assets, coalesce(sum(size_bytes), 0)::bigint AS bytes FROM media_assets GROUP BY kind ORDER BY kind`);
    const total = rows.reduce((s, r) => s + Number(r.bytes), 0);
    return { driver: this.storage.name, totalBytes: total, byKind: rows.map((r) => ({ kind: r.kind, assets: r.assets, bytes: Number(r.bytes) })) };
  }

  async activity(days = 30) {
    const [perDay, topTracks, topArtists] = await Promise.all([
      this.db.query(
        `SELECT date_trunc('day', played_at)::date AS day, count(*)::int AS plays, count(DISTINCT user_id)::int AS listeners
         FROM playback_events WHERE played_at > now() - make_interval(days => $1) GROUP BY 1 ORDER BY 1`,
        [days],
      ),
      this.db.query(
        `SELECT t.id, t.title, ar.name AS artist, count(*)::int AS plays FROM playback_events pe JOIN tracks t ON t.id = pe.track_id
         JOIN artists ar ON ar.id = t.artist_id WHERE pe.played_at > now() - make_interval(days => $1)
         GROUP BY t.id, ar.name ORDER BY plays DESC LIMIT 20`,
        [days],
      ),
      this.db.query(
        `SELECT ar.id, ar.name, count(*)::int AS plays FROM playback_events pe JOIN tracks t ON t.id = pe.track_id
         JOIN artists ar ON ar.id = t.artist_id WHERE pe.played_at > now() - make_interval(days => $1)
         GROUP BY ar.id ORDER BY plays DESC LIMIT 20`,
        [days],
      ),
    ]);
    return { perDay, topTracks, topArtists };
  }

  // ---------------------------------------------------------------- catalog
  async tracks(page: PageQuery, q?: string, status?: string) {
    const rows = await this.db.query(
      `SELECT ${trackSelect('NULL')}, count(*) OVER () AS total FROM ${trackFrom}
       WHERE ($3::text IS NULL OR t.title ILIKE '%' || $3 || '%' OR ar.name ILIKE '%' || $3 || '%' OR al.title ILIKE '%' || $3 || '%')
         AND ($4::media_status IS NULL OR t.status = $4)
       ORDER BY t.created_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, q || null, status || null],
    );
    return toPage(rows.map((r) => ({ ...presentTrack(r), createdAt: r.created_at, playCount: Number(r.play_count) })), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async track(id: string) {
    const row = await this.db.one(`SELECT ${trackSelect('NULL')}, t.isrc FROM ${trackFrom} WHERE t.id = $1`, [id]);
    if (!row) throw notFound('Track');
    const [renditions, lyrics] = await Promise.all([
      this.db.query(
        `SELECT tr.profile, a.codec, a.bitrate, a.sample_rate, a.bit_depth, a.is_lossless, a.size_bytes, (a.id = t.original_asset_id) AS is_original
         FROM track_renditions tr JOIN media_assets a ON a.id = tr.asset_id JOIN tracks t ON t.id = tr.track_id WHERE tr.track_id = $1 ORDER BY tr.profile`,
        [id],
      ),
      this.db.one('SELECT kind, content, source, license_note, language FROM lyrics WHERE track_id = $1', [id]),
    ]);
    return { ...presentTrack(row), isrc: row.isrc, playCount: Number(row.play_count), renditions, lyrics };
  }

  async updateTrack(actorId: string, id: string, patch: TrackPatch) {
    await this.db.tx(async (client) => {
      const t = await this.db.one('SELECT id FROM tracks WHERE id = $1 FOR UPDATE', [id], client);
      if (!t) throw notFound('Track');
      let artistId: string | null = null;
      if (patch.artistName) {
        artistId = (await this.db.one(
          `INSERT INTO artists (name) VALUES ($1) ON CONFLICT ((lower(name))) DO UPDATE SET name = artists.name RETURNING id`,
          [patch.artistName.trim()],
          client,
        )).id;
      }
      await this.db.query(
        `UPDATE tracks SET title = coalesce($2, title), artist_id = coalesce($3, artist_id),
           album_id = CASE WHEN $4::boolean THEN $5::uuid ELSE album_id END,
           track_number = CASE WHEN $6::boolean THEN $7::int ELSE track_number END,
           disc_number = coalesce($8, disc_number), explicit = coalesce($9, explicit), genres = coalesce($10, genres),
           moods = coalesce($11, moods), downloadable = coalesce($12, downloadable),
           isrc = CASE WHEN $13::boolean THEN $14 ELSE isrc END
         WHERE id = $1`,
        [id, patch.title?.trim() || null, artistId, patch.albumId !== undefined, patch.albumId ?? null, patch.trackNumber !== undefined, patch.trackNumber ?? null,
          patch.discNumber ?? null, patch.explicit ?? null, patch.genres?.map((g) => g.toLowerCase().trim()) ?? null,
          patch.moods?.map((g) => g.toLowerCase().trim()) ?? null, patch.downloadable ?? null, patch.isrc !== undefined, patch.isrc ?? null],
        client,
      );
      await this.audit.record({ actorId, action: 'track.update', targetType: 'track', targetId: id, metadata: { fields: Object.keys(patch) } }, client);
    });
    return this.track(id);
  }

  /** Removes the catalog entry; media is deleted only where no other entity references it. */
  async deleteTrack(actorId: string, id: string) {
    const t = await this.db.one('SELECT id, original_asset_id, album_id FROM tracks WHERE id = $1', [id]);
    if (!t) throw notFound('Track');
    const renditions = await this.db.query('SELECT asset_id FROM track_renditions WHERE track_id = $1', [id]);
    await this.db.query('DELETE FROM tracks WHERE id = $1', [id]);
    const deleted = await this.assets.deleteIfUnreferenced([t.original_asset_id, ...renditions.map((r) => r.asset_id)]);
    await this.audit.record({ actorId, action: 'track.delete', targetType: 'track', targetId: id, metadata: { deletedAssets: deleted.length } });
    return { deleted: true, deletedAssets: deleted.length };
  }

  async bulkTracks(actorId: string, ids: string[], action: string, value?: unknown) {
    if (ids.length === 0) throw badRequest('empty', 'No tracks selected');
    switch (action) {
      case 'set_downloadable':
        await this.db.query('UPDATE tracks SET downloadable = $2 WHERE id = ANY($1::uuid[])', [ids, !!value]);
        break;
      case 'set_explicit':
        await this.db.query('UPDATE tracks SET explicit = $2 WHERE id = ANY($1::uuid[])', [ids, !!value]);
        break;
      case 'add_genre':
        if (typeof value !== 'string' || !value.trim()) throw badRequest('invalid_value', 'Genre required');
        await this.db.query(
          `UPDATE tracks SET genres = array_append(genres, $2) WHERE id = ANY($1::uuid[]) AND NOT ($2 = ANY(genres))`,
          [ids, value.trim().toLowerCase()],
        );
        break;
      case 'reprocess':
        for (const id of ids) await this.jobs.create('reprocess', { trackId: id }, actorId);
        break;
      case 'delete':
        for (const id of ids) await this.deleteTrack(actorId, id);
        break;
      default:
        throw badRequest('invalid_action', 'Unknown bulk action');
    }
    await this.audit.record({ actorId, action: `track.bulk.${action}`, metadata: { count: ids.length } });
    return { updated: ids.length };
  }

  async setLyrics(actorId: string, trackId: string, content: string, source?: string, license?: string) {
    const t = await this.db.one('SELECT id FROM tracks WHERE id = $1', [trackId]);
    if (!t) throw notFound('Track');
    await this.processor.saveLyrics(trackId, content, source ?? 'manual', license ?? null);
    await this.audit.record({ actorId, action: 'lyrics.update', targetType: 'track', targetId: trackId });
    return { trackId };
  }

  async deleteLyrics(actorId: string, trackId: string) {
    await this.db.query('DELETE FROM lyrics WHERE track_id = $1', [trackId]);
    await this.audit.record({ actorId, action: 'lyrics.delete', targetType: 'track', targetId: trackId });
  }

  async albums(page: PageQuery, q?: string) {
    const rows = await this.db.query(
      `SELECT ${albumSelect}, count(*) OVER () AS total FROM ${albumFrom}
       WHERE $3::text IS NULL OR al.title ILIKE '%' || $3 || '%' OR ar.name ILIKE '%' || $3 || '%'
       ORDER BY al.created_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, q || null],
    );
    return toPage(rows.map(presentAlbum), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async updateAlbum(actorId: string, id: string, p: { title?: string; albumType?: string; releaseDate?: string | null; genres?: string[]; label?: string | null; explicit?: boolean; artistId?: string }) {
    const row = await this.db.one(
      `UPDATE albums SET title = coalesce($2, title), album_type = coalesce($3::album_type, album_type),
         release_date = CASE WHEN $4::boolean THEN $5::date ELSE release_date END, genres = coalesce($6, genres),
         label = CASE WHEN $7::boolean THEN $8 ELSE label END, explicit = coalesce($9, explicit), artist_id = coalesce($10, artist_id)
       WHERE id = $1 RETURNING id`,
      [id, p.title?.trim() || null, p.albumType ?? null, p.releaseDate !== undefined, p.releaseDate ?? null, p.genres ?? null,
        p.label !== undefined, p.label ?? null, p.explicit ?? null, p.artistId ?? null],
    );
    if (!row) throw notFound('Album');
    await this.audit.record({ actorId, action: 'album.update', targetType: 'album', targetId: id, metadata: { fields: Object.keys(p) } });
    const a = await this.db.one(`SELECT ${albumSelect} FROM ${albumFrom} WHERE al.id = $1`, [id]);
    return presentAlbum(a);
  }

  async deleteAlbum(actorId: string, id: string, withTracks: boolean) {
    const album = await this.db.one('SELECT id, artwork_asset_id FROM albums WHERE id = $1', [id]);
    if (!album) throw notFound('Album');
    const tracks = await this.db.query('SELECT id FROM tracks WHERE album_id = $1', [id]);
    if (tracks.length && !withTracks) throw conflict('album_not_empty', `Album has ${tracks.length} track(s); delete them or pass withTracks=true`);
    for (const t of tracks) await this.deleteTrack(actorId, t.id);
    await this.db.query('DELETE FROM albums WHERE id = $1', [id]);
    await this.assets.deleteIfUnreferenced([album.artwork_asset_id]);
    await this.audit.record({ actorId, action: 'album.delete', targetType: 'album', targetId: id, metadata: { tracks: tracks.length } });
    return { deleted: true, tracks: tracks.length };
  }

  async artists(page: PageQuery, q?: string) {
    const rows = await this.db.query(
      `SELECT ${artistSelect}, (SELECT count(*)::int FROM tracks t WHERE t.artist_id = ar.id) AS track_count,
         (SELECT count(*)::int FROM albums al WHERE al.artist_id = ar.id) AS album_count, count(*) OVER () AS total
       FROM artists ar WHERE $3::text IS NULL OR ar.name ILIKE '%' || $3 || '%' ORDER BY lower(ar.name) LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, q || null],
    );
    return toPage(rows.map((r) => ({ ...presentArtist(r), trackCount: r.track_count, albumCount: r.album_count })), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async updateArtist(actorId: string, id: string, p: { name?: string; bio?: string | null; genres?: string[]; sortName?: string | null }) {
    const row = await this.db.one(
      `UPDATE artists SET name = coalesce($2, name), bio = CASE WHEN $3::boolean THEN $4 ELSE bio END, genres = coalesce($5, genres),
         sort_name = CASE WHEN $6::boolean THEN $7 ELSE sort_name END WHERE id = $1 RETURNING id`,
      [id, p.name?.trim() || null, p.bio !== undefined, p.bio ?? null, p.genres ?? null, p.sortName !== undefined, p.sortName ?? null],
    );
    if (!row) throw notFound('Artist');
    await this.audit.record({ actorId, action: 'artist.update', targetType: 'artist', targetId: id });
    return presentArtist(await this.db.one(`SELECT ${artistSelect} FROM artists ar WHERE ar.id = $1`, [id]));
  }

  async deleteArtist(actorId: string, id: string) {
    const refs = await this.db.one(
      `SELECT (SELECT count(*) FROM tracks WHERE artist_id = $1) + (SELECT count(*) FROM albums WHERE artist_id = $1) AS n, (SELECT artwork_asset_id FROM artists WHERE id = $1) AS art`,
      [id],
    );
    if (Number(refs.n) > 0) throw conflict('artist_in_use', 'Artist still has albums or tracks');
    const row = await this.db.one('DELETE FROM artists WHERE id = $1 RETURNING id', [id]);
    if (!row) throw notFound('Artist');
    await this.assets.deleteIfUnreferenced([refs.art]);
    await this.audit.record({ actorId, action: 'artist.delete', targetType: 'artist', targetId: id });
    return { deleted: true };
  }

  async videos(page: PageQuery, q?: string) {
    const rows = await this.db.query(
      `SELECT ${videoSelect('NULL')}, count(*) OVER () AS total FROM ${videoFrom}
       WHERE $3::text IS NULL OR v.title ILIKE '%' || $3 || '%' ORDER BY v.created_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, q || null],
    );
    return toPage(rows.map(presentVideo), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async updateVideo(actorId: string, id: string, p: { title?: string; description?: string | null; trackId?: string | null; artistName?: string; genres?: string[]; explicit?: boolean; downloadable?: boolean }) {
    let artistId: string | null = null;
    if (p.artistName) {
      artistId = (await this.db.one(`INSERT INTO artists (name) VALUES ($1) ON CONFLICT ((lower(name))) DO UPDATE SET name = artists.name RETURNING id`, [p.artistName.trim()])).id;
    }
    const row = await this.db.one(
      `UPDATE videos SET title = coalesce($2, title), description = CASE WHEN $3::boolean THEN $4 ELSE description END,
         track_id = CASE WHEN $5::boolean THEN $6::uuid ELSE track_id END, artist_id = coalesce($7, artist_id),
         genres = coalesce($8, genres), explicit = coalesce($9, explicit), downloadable = coalesce($10, downloadable)
       WHERE id = $1 RETURNING id`,
      [id, p.title?.trim() || null, p.description !== undefined, p.description ?? null, p.trackId !== undefined, p.trackId ?? null, artistId,
        p.genres ?? null, p.explicit ?? null, p.downloadable ?? null],
    );
    if (!row) throw notFound('Video');
    await this.audit.record({ actorId, action: 'video.update', targetType: 'video', targetId: id });
    return presentVideo(await this.db.one(`SELECT ${videoSelect('NULL')} FROM ${videoFrom} WHERE v.id = $1`, [id]));
  }

  async deleteVideo(actorId: string, id: string) {
    const v = await this.db.one('SELECT * FROM videos WHERE id = $1', [id]);
    if (!v) throw notFound('Video');
    const subs = await this.db.query('SELECT asset_id, original_asset_id FROM subtitle_tracks WHERE video_id = $1', [id]);
    await this.db.query('DELETE FROM videos WHERE id = $1', [id]);
    const deleted = await this.assets.deleteIfUnreferenced([
      v.original_asset_id, v.hls_asset_id, v.thumbnail_asset_id, v.preview_asset_id, v.audio_asset_id,
      ...subs.flatMap((s) => [s.asset_id, s.original_asset_id]),
    ]);
    await this.audit.record({ actorId, action: 'video.delete', targetType: 'video', targetId: id, metadata: { deletedAssets: deleted.length } });
    return { deleted: true, deletedAssets: deleted.length };
  }

  async updateSubtitle(actorId: string, id: string, p: { label?: string; isDefault?: boolean; forced?: boolean }) {
    await this.db.tx(async (client) => {
      const s = await this.db.one('SELECT video_id FROM subtitle_tracks WHERE id = $1', [id], client);
      if (!s) throw notFound('Subtitle');
      if (p.isDefault) await this.db.query('UPDATE subtitle_tracks SET is_default = false WHERE video_id = $1', [s.video_id], client);
      await this.db.query(
        'UPDATE subtitle_tracks SET label = coalesce($2, label), is_default = coalesce($3, is_default), forced = coalesce($4, forced) WHERE id = $1',
        [id, p.label ?? null, p.isDefault ?? null, p.forced ?? null],
        client,
      );
    });
    await this.audit.record({ actorId, action: 'subtitle.update', targetType: 'subtitle', targetId: id });
    return { id };
  }

  async deleteSubtitle(actorId: string, id: string) {
    const s = await this.db.one('DELETE FROM subtitle_tracks WHERE id = $1 RETURNING asset_id, original_asset_id', [id]);
    if (!s) throw notFound('Subtitle');
    await this.assets.deleteIfUnreferenced([s.asset_id, s.original_asset_id]);
    await this.audit.record({ actorId, action: 'subtitle.delete', targetType: 'subtitle', targetId: id });
  }

  // ---------------------------------------------------------------- users
  private static readonly USER_COLUMNS = `u.id, u.email, u.display_name, u.role, u.email_verified_at, u.disabled_at, u.created_at,
         (SELECT max(played_at) FROM playback_events pe WHERE pe.user_id = u.id) AS last_played_at,
         (SELECT max(created_at) FROM refresh_tokens rt WHERE rt.user_id = u.id) AS last_session_at`;

  private presentUser(u: any) {
    const times = [u.last_played_at, u.last_session_at].filter(Boolean).map((t: Date) => new Date(t).getTime());
    return {
      id: u.id, email: u.email, displayName: u.display_name, role: u.role, emailVerified: !!u.email_verified_at,
      disabled: !!u.disabled_at, createdAt: u.created_at, lastActiveAt: times.length ? new Date(Math.max(...times)).toISOString() : null,
      lastPlayedAt: u.last_played_at,
    };
  }

  async users(page: PageQuery, q?: string, role?: string) {
    const rows = await this.db.query(
      `SELECT ${AdminService.USER_COLUMNS}, count(*) OVER () AS total
       FROM users u WHERE ($3::text IS NULL OR u.email ILIKE '%' || $3 || '%' OR u.display_name ILIKE '%' || $3 || '%')
         AND ($4::user_role IS NULL OR u.role = $4)
       ORDER BY u.created_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, q || null, role || null],
    );
    return toPage(rows.map((u) => this.presentUser(u)), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async user(id: string, client?: Queryable) {
    const u = await this.db.one(`SELECT ${AdminService.USER_COLUMNS} FROM users u WHERE u.id = $1`, [id], client);
    if (!u) throw notFound('User');
    return this.presentUser(u);
  }

  /**
   * Admin-created accounts are email-verified. Without a password (or with sendInvite) the user gets a
   * set-your-password link (the password-reset flow with a longer expiry).
   */
  async createUser(actorId: string, p: { email: string; displayName: string; role: Role; password?: string; sendInvite?: boolean }, ip?: string) {
    const passwordHash = p.password ? await this.auth.hashPassword(p.password) : null;
    const row = await this.db.one(
      `INSERT INTO users (email, password_hash, display_name, role, email_verified_at) VALUES ($1, $2, $3, $4, now())
       ON CONFLICT (email) DO NOTHING RETURNING id, email`,
      [p.email.trim(), passwordHash, p.displayName.trim(), p.role],
    );
    if (!row) throw conflict('email_taken', 'An account with this email already exists');
    const invite = !p.password || !!p.sendInvite;
    await this.audit.record({ actorId, action: 'user.admin_create', targetType: 'user', targetId: row.id, metadata: { role: p.role, withPassword: !!p.password, invite }, ip });
    if (invite) await this.auth.sendPasswordReset(row.id, row.email, { invite: true });
    return this.user(row.id);
  }

  async updateUser(
    actorId: string,
    id: string,
    p: { role?: Role; disabled?: boolean; email?: string; displayName?: string; emailVerified?: boolean },
    ip?: string,
  ) {
    return this.db.tx(async (client) => {
      const u = await this.db.one('SELECT id, role, disabled_at FROM users WHERE id = $1 FOR UPDATE', [id], client);
      if (!u) throw notFound('User');
      const losingAdmin = u.role === 'admin' && !u.disabled_at && ((p.role && p.role !== 'admin') || p.disabled === true);
      if (losingAdmin) {
        await this.db.query('SELECT pg_advisory_xact_lock(727002)', [], client);
        const n = await this.db.one(`SELECT count(*)::int AS n FROM users WHERE role = 'admin' AND disabled_at IS NULL AND id <> $1`, [id], client);
        if (n.n === 0) throw conflict('last_admin', 'At least one active administrator is required');
      }
      if (p.email !== undefined) {
        const taken = await this.db.one('SELECT id FROM users WHERE email = $1 AND id <> $2', [p.email.trim(), id], client);
        if (taken) throw conflict('email_taken', 'An account with this email already exists');
      }
      await this.db.query(
        `UPDATE users SET role = coalesce($2, role),
           disabled_at = CASE WHEN $3::boolean IS NULL THEN disabled_at WHEN $3 THEN coalesce(disabled_at, now()) ELSE NULL END,
           email = coalesce($4, email), display_name = coalesce($5, display_name),
           email_verified_at = CASE WHEN $6::boolean IS NULL THEN email_verified_at WHEN $6 THEN coalesce(email_verified_at, now()) ELSE NULL END
         WHERE id = $1`,
        [id, p.role ?? null, p.disabled ?? null, p.email?.trim() ?? null, p.displayName?.trim() || null, p.emailVerified ?? null],
        client,
      );
      if (p.disabled) await this.db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [id], client);
      await this.audit.record({ actorId, action: 'user.admin_update', targetType: 'user', targetId: id, metadata: { fields: Object.keys(p), role: p.role, disabled: p.disabled }, ip }, client);
      return this.user(id, client);
    });
  }

  /** Sets a new password (policy enforced by the DTO) and revokes all of the user's sessions. */
  async setUserPassword(actorId: string, id: string, password: string, ip?: string) {
    await this.db.tx(async (client) => {
      const u = await this.db.one('SELECT id FROM users WHERE id = $1 FOR UPDATE', [id], client);
      if (!u) throw notFound('User');
      await this.auth.setPassword(id, password, client);
      await this.audit.record({ actorId, action: 'user.admin_set_password', targetType: 'user', targetId: id, ip }, client);
    });
  }

  async sendUserReset(actorId: string, id: string, ip?: string) {
    const u = await this.db.one('SELECT id, email, disabled_at FROM users WHERE id = $1', [id]);
    if (!u) throw notFound('User');
    if (u.disabled_at) throw conflict('account_disabled', 'This account is disabled; enable it before sending a reset link');
    await this.auth.sendPasswordReset(u.id, u.email);
    await this.audit.record({ actorId, action: 'user.admin_send_reset', targetType: 'user', targetId: id, ip });
  }

  /** Same code path as self-service deletion (personal data and stored objects are removed). */
  async deleteUser(actorId: string, id: string, ip?: string) {
    if (actorId === id) throw conflict('cannot_delete_self', 'You cannot delete your own account from the admin dashboard');
    await this.usersService.deleteAccount(id, { actorId, ip });
  }

  // ---------------------------------------------------------------- home, audit, system
  homeSections() {
    return this.db.query('SELECT id, kind, title, position, enabled, config FROM home_sections ORDER BY position');
  }

  async saveHomeSections(actorId: string, sections: { id?: string; kind: string; title: string; enabled: boolean; config?: object }[]) {
    await this.db.tx(async (client) => {
      const keep = sections.filter((s) => s.id).map((s) => s.id);
      await this.db.query('DELETE FROM home_sections WHERE NOT (id = ANY($1::uuid[]))', [keep], client);
      for (const [i, s] of sections.entries()) {
        if (s.id) {
          await this.db.query('UPDATE home_sections SET kind = $2, title = $3, position = $4, enabled = $5, config = $6 WHERE id = $1', [s.id, s.kind, s.title, i, s.enabled, JSON.stringify(s.config ?? {})], client);
        } else {
          await this.db.query('INSERT INTO home_sections (kind, title, position, enabled, config) VALUES ($1, $2, $3, $4, $5)', [s.kind, s.title, i, s.enabled, JSON.stringify(s.config ?? {})], client);
        }
      }
      await this.audit.record({ actorId, action: 'home.update', metadata: { sections: sections.length } }, client);
    });
    return this.homeSections();
  }

  async auditLogs(page: PageQuery, action?: string, actor?: string) {
    const rows = await this.db.query(
      `SELECT a.id, a.action, a.target_type, a.target_id, a.metadata, host(a.ip) AS ip, a.created_at, u.email AS actor_email
       FROM audit_logs a LEFT JOIN users u ON u.id = a.actor_id
       WHERE ($3::text IS NULL OR a.action LIKE $3 || '%') AND ($4::text IS NULL OR u.email ILIKE '%' || $4 || '%')
       ORDER BY a.id DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, action || null, actor || null],
    );
    return toPage(rows.map((r) => ({ id: Number(r.id), action: r.action, targetType: r.target_type, targetId: r.target_id, metadata: r.metadata, ip: r.ip, actor: r.actor_email, createdAt: r.created_at })), page);
  }

  async system() {
    const [database, redis, storage, jobs, migrations] = await Promise.all([
      this.db.ping(),
      this.redis.ping(),
      this.storage.ping().catch(() => false),
      this.jobs.stats(),
      this.db.query('SELECT name, applied_at FROM schema_migrations ORDER BY name'),
    ]);
    const workers = await this.redis.client.keys('worker:heartbeat:*').catch(() => []);
    return {
      checks: { database, redis, storage, workers: workers.length },
      jobs,
      migrations,
      runtime: { node: process.version, uptimeSeconds: Math.round(process.uptime()), memoryMb: Math.round(process.memoryUsage().rss / 1048576) },
    };
  }

  /** Non-secret configuration, for operators. Secrets are never returned. */
  configSummary() {
    const c = this.config;
    return {
      environment: c.NODE_ENV,
      publicBaseUrl: c.PUBLIC_BASE_URL,
      corsOrigins: c.CORS_ORIGINS,
      storageDriver: c.STORAGE_DRIVER,
      s3: c.STORAGE_DRIVER === 's3' ? { endpoint: c.S3_ENDPOINT, bucket: c.S3_BUCKET, region: c.S3_REGION } : null,
      tokens: { accessTtlSeconds: c.ACCESS_TOKEN_TTL_SECONDS, refreshTtlDays: c.REFRESH_TOKEN_TTL_DAYS, mediaUrlTtlSeconds: c.MEDIA_URL_TTL_SECONDS },
      media: { maxUploadBytes: c.MAX_UPLOAD_BYTES, ffmpegThreads: c.FFMPEG_THREADS, workerConcurrency: c.WORKER_CONCURRENCY, timeoutSeconds: c.FFMPEG_TIMEOUT_SECONDS },
      imports: { allowedHosts: c.IMPORT_ALLOWED_HOSTS, allowedDirs: c.IMPORT_ALLOWED_DIRS },
      integrations: { smtp: !!c.SMTP_URL, googleSignIn: !!(c.GOOGLE_IOS_CLIENT_ID || c.GOOGLE_WEB_CLIENT_ID), youtube: !!c.YOUTUBE_API_KEY },
    };
  }
}
