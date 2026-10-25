import { randomUUID } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { verify } from '@node-rs/argon2';
import { AuditService } from '../audit/audit.service.js';
import { toPublicUser } from '../auth/auth.service.js';
import { badRequest, conflict, notFound, unauthorized } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { AssetsService } from '../media/assets.service.js';
import { STORAGE } from '../storage/storage.module.js';
import type { StorageDriver } from '../storage/storage.driver.js';

export interface ProfilePatch {
  displayName?: string;
  allowExplicit?: boolean;
  historyEnabled?: boolean;
  personalizationEnabled?: boolean;
}

/** Detects JPEG/PNG/WebP by magic bytes; the client-supplied MIME type is never trusted. */
export function sniffImage(buf: Buffer): { mime: string; ext: string } | null {
  if (buf.length > 3 && buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return { mime: 'image/jpeg', ext: 'jpg' };
  if (buf.length > 8 && buf.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return { mime: 'image/png', ext: 'png' };
  if (buf.length > 12 && buf.subarray(0, 4).toString() === 'RIFF' && buf.subarray(8, 12).toString() === 'WEBP') return { mime: 'image/webp', ext: 'webp' };
  return null;
}

@Injectable()
export class UsersService {
  constructor(
    private readonly db: DbService,
    private readonly audit: AuditService,
    private readonly assets: AssetsService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
  ) {}

  async me(userId: string) {
    const u = await this.db.one('SELECT * FROM users WHERE id = $1', [userId]);
    if (!u) throw notFound('User');
    return {
      ...toPublicUser(u),
      allowExplicit: u.allow_explicit,
      historyEnabled: u.history_enabled,
      personalizationEnabled: u.personalization_enabled,
      hasPassword: !!u.password_hash,
      appleLinked: !!u.apple_sub,
      preferences: u.preferences,
      preferencesVersion: u.preferences_version,
      createdAt: u.created_at,
    };
  }

  async update(userId: string, patch: ProfilePatch) {
    await this.db.query(
      `UPDATE users SET display_name = coalesce($2, display_name), allow_explicit = coalesce($3, allow_explicit),
         history_enabled = coalesce($4, history_enabled), personalization_enabled = coalesce($5, personalization_enabled)
       WHERE id = $1`,
      [userId, patch.displayName?.trim() || null, patch.allowExplicit ?? null, patch.historyEnabled ?? null, patch.personalizationEnabled ?? null],
    );
    return this.me(userId);
  }

  /**
   * Preferences (quality, crossfade, subtitle language, theme, ...) sync across devices.
   * Compare-and-swap on the version prevents a stale device from overwriting newer settings.
   */
  async putPreferences(userId: string, preferences: Record<string, unknown>, baseVersion: number) {
    if (JSON.stringify(preferences).length > 32 * 1024) throw badRequest('preferences_too_large', 'Preferences exceed 32 KB');
    const row = await this.db.one(
      `UPDATE users SET preferences = $2, preferences_version = preferences_version + 1
       WHERE id = $1 AND preferences_version = $3 RETURNING preferences, preferences_version`,
      [userId, JSON.stringify(preferences), baseVersion],
    );
    if (!row) {
      const cur = await this.db.one('SELECT preferences, preferences_version FROM users WHERE id = $1', [userId]);
      throw conflict('version_conflict', 'Preferences changed on another device', { preferences: cur?.preferences, version: cur?.preferences_version });
    }
    return { preferences: row.preferences, version: row.preferences_version };
  }

  async setAvatar(userId: string, file: Buffer) {
    if (file.length > 5 * 1024 * 1024) throw badRequest('file_too_large', 'Avatar must be at most 5 MB');
    const kind = sniffImage(file);
    if (!kind) throw badRequest('unsupported_image', 'Avatar must be a JPEG, PNG or WebP image');
    const id = randomUUID();
    const key = `avatars/${userId}/${id}.${kind.ext}`;
    await this.storage.putBuffer(key, file, kind.mime);
    const old = await this.db.one('SELECT avatar_asset_id FROM users WHERE id = $1', [userId]);
    await this.db.tx(async (client) => {
      await this.db.query(
        `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes) VALUES ($1, 'avatar', $2, $3, $4)`,
        [id, key, kind.mime, file.length],
        client,
      );
      await this.db.query('UPDATE users SET avatar_asset_id = $2 WHERE id = $1', [userId, id], client);
    });
    if (old?.avatar_asset_id) await this.deleteAsset(old.avatar_asset_id);
    return this.me(userId);
  }

  async removeAvatar(userId: string) {
    const old = await this.db.one('SELECT avatar_asset_id FROM users WHERE id = $1', [userId]);
    await this.db.query('UPDATE users SET avatar_asset_id = NULL WHERE id = $1', [userId]);
    if (old?.avatar_asset_id) await this.deleteAsset(old.avatar_asset_id);
  }

  private async deleteAsset(assetId: string) {
    const a = await this.db.one(`DELETE FROM media_assets WHERE id = $1 AND kind = 'avatar' RETURNING storage_key`, [assetId]);
    if (a) await this.storage.delete(a.storage_key).catch(() => undefined);
  }

  async sessions(userId: string) {
    const rows = await this.db.query(
      `SELECT DISTINCT ON (family_id) family_id, user_agent, created_at, expires_at
       FROM refresh_tokens WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()
       ORDER BY family_id, created_at DESC`,
      [userId],
    );
    return { items: rows.map((r) => ({ id: r.family_id, device: r.user_agent, lastActiveAt: r.created_at, expiresAt: r.expires_at })) };
  }

  async revokeSession(userId: string, familyId: string) {
    await this.db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND family_id = $2 AND revoked_at IS NULL', [userId, familyId]);
  }

  /** GDPR-style export of everything stored about the user. Never includes password hashes or tokens. */
  async export(userId: string) {
    const q = (sql: string) => this.db.query(sql, [userId]);
    const [profile, liked, albums, artists, videos, playlists, items, history, progress, searches, prefs] = await Promise.all([
      this.me(userId),
      q('SELECT track_id, created_at FROM liked_tracks WHERE user_id = $1'),
      q('SELECT album_id, created_at FROM saved_albums WHERE user_id = $1'),
      q('SELECT artist_id, created_at FROM followed_artists WHERE user_id = $1'),
      q('SELECT video_id, created_at FROM liked_videos WHERE user_id = $1'),
      q('SELECT id, title, description, visibility, created_at, updated_at FROM playlists WHERE owner_id = $1'),
      q('SELECT pi.playlist_id, pi.track_id, pi.video_id, pi.position FROM playlist_items pi JOIN playlists p ON p.id = pi.playlist_id WHERE p.owner_id = $1'),
      q('SELECT track_id, video_id, played_at, duration_played_ms, completed, context_type, context_id, device_id FROM playback_events WHERE user_id = $1 ORDER BY played_at'),
      q('SELECT video_id, position_ms, completed, updated_at FROM video_progress WHERE user_id = $1'),
      q('SELECT query, created_at FROM recent_searches WHERE user_id = $1'),
      q('SELECT state, updated_at FROM playback_state WHERE user_id = $1'),
    ]);
    await this.audit.record({ actorId: userId, action: 'user.export', targetType: 'user', targetId: userId });
    return {
      exportedAt: new Date().toISOString(),
      profile,
      library: { likedTracks: liked, savedAlbums: albums, followedArtists: artists, likedVideos: videos },
      playlists: playlists.map((p) => ({ ...p, items: items.filter((i) => i.playlist_id === p.id) })),
      playbackHistory: history,
      videoProgress: progress,
      recentSearches: searches,
      playbackState: prefs[0] ?? null,
    };
  }

  /** Permanently deletes the account. Requires the password for password accounts. */
  async delete(userId: string, password?: string) {
    const u = await this.db.one('SELECT password_hash FROM users WHERE id = $1', [userId]);
    if (!u) throw notFound('User');
    if (u.password_hash && !(password && (await verify(u.password_hash, password).catch(() => false)))) {
      throw unauthorized('invalid_credentials', 'Password is incorrect');
    }
    await this.deleteAccount(userId);
  }

  /**
   * Shared deletion path (self-service and admin): removes the user row (personal data cascades: library,
   * history, playlists, sessions, tokens, uploads) and then the stored objects nothing else references
   * (avatar, artwork of the user's own playlists). The last active administrator can never be deleted.
   */
  async deleteAccount(userId: string, opts: { actorId?: string | null; ip?: string } = {}) {
    const assetIds = await this.db.tx(async (client) => {
      const u = await this.db.one('SELECT id, email, role, avatar_asset_id, disabled_at FROM users WHERE id = $1 FOR UPDATE', [userId], client);
      if (!u) throw notFound('User');
      if (u.role === 'admin' && !u.disabled_at) {
        // Serialise concurrent admin deletions so two requests cannot remove the last two admins.
        await this.db.query('SELECT pg_advisory_xact_lock(727002)', [], client);
        const others = await this.db.one(`SELECT count(*)::int AS n FROM users WHERE role = 'admin' AND disabled_at IS NULL AND id <> $1`, [userId], client);
        if (others.n === 0) throw conflict('last_admin', 'The last active administrator cannot be deleted');
      }
      const playlistArt = await this.db.query('SELECT artwork_asset_id FROM playlists WHERE owner_id = $1 AND artwork_asset_id IS NOT NULL', [userId], client);
      await this.db.query('DELETE FROM users WHERE id = $1', [userId], client);
      await this.audit.record(
        { actorId: opts.actorId && opts.actorId !== userId ? opts.actorId : null, action: opts.actorId && opts.actorId !== userId ? 'user.admin_delete' : 'user.deleted', targetType: 'user', targetId: userId, ip: opts.ip },
        client,
      );
      return [u.avatar_asset_id, ...playlistArt.map((p) => p.artwork_asset_id)];
    });
    await this.assets.deleteIfUnreferenced(assetIds);
  }
}
