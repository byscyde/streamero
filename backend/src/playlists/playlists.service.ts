import { Injectable } from '@nestjs/common';
import type pg from 'pg';
import { AuditService } from '../audit/audit.service.js';
import { hasRole, type AuthUser } from '../common/auth-user.js';
import { badRequest, conflict, forbidden, notFound } from '../common/errors.js';
import { toPage, type PageQuery } from '../common/pagination.js';
import { playlistFrom, playlistSelect, presentPlaylist, presentTrack, presentVideo, trackSelect, trackFrom, videoSelect, videoFrom } from '../catalog/presenters.js';
import { DbService } from '../db/db.service.js';

export interface PlaylistInput {
  title?: string;
  description?: string | null;
  visibility?: 'private' | 'unlisted' | 'public';
  isCollaborative?: boolean;
}

const MAX_ITEMS = 10_000;

@Injectable()
export class PlaylistsService {
  constructor(
    private readonly db: DbService,
    private readonly audit: AuditService,
  ) {}

  async create(user: AuthUser, input: PlaylistInput & { title: string; editorial?: boolean }) {
    if (input.editorial && !hasRole(user, 'editor')) throw forbidden('Only editors can create editorial playlists');
    const row = await this.db.one(
      `INSERT INTO playlists (owner_id, title, description, visibility, is_collaborative, is_editorial)
       VALUES ($1, $2, $3, $4, $5, $6) RETURNING id`,
      [
        input.editorial ? null : user.id,
        input.title.trim(),
        input.description?.trim() || null,
        input.editorial ? 'public' : (input.visibility ?? 'private'),
        input.isCollaborative ?? false,
        !!input.editorial,
      ],
    );
    return this.get(row.id, user);
  }

  /** Loads a playlist row and enforces read access. Private playlists are visible to owner and collaborators only. */
  private async load(id: string, viewer: AuthUser | null, client?: pg.PoolClient) {
    const row = await this.db.one(`SELECT ${playlistSelect('$1')} FROM ${playlistFrom} WHERE p.id = $2`, [viewer?.id ?? null, id], client);
    if (!row) throw notFound('Playlist');
    const isCollaborator =
      viewer &&
      (await this.db.one('SELECT 1 AS ok FROM playlist_collaborators WHERE playlist_id = $1 AND user_id = $2', [id, viewer.id], client));
    const canRead =
      row.visibility !== 'private' || row.is_editorial || row.owner_id === viewer?.id || !!isCollaborator || hasRole(viewer ?? undefined, 'editor');
    // Respond 404 rather than 403 so private playlist ids cannot be probed.
    if (!canRead) throw notFound('Playlist');
    return row;
  }

  private canEdit(row: any, user: AuthUser) {
    if (row.is_editorial) return hasRole(user, 'editor');
    return row.owner_id === user.id || !!row.can_edit;
  }

  async get(id: string, viewer: AuthUser | null, page: PageQuery = { limit: 100, offset: 0 }) {
    const row = await this.load(id, viewer);
    const items = await this.items(id, viewer?.id ?? null, page);
    return { playlist: presentPlaylist(row, viewer?.id), items };
  }

  async byShareToken(token: string, viewer: AuthUser | null) {
    const p = await this.db.one(`SELECT id FROM playlists WHERE share_token = $1 AND visibility <> 'private'`, [token]);
    if (!p) throw notFound('Playlist');
    return this.get(p.id, viewer);
  }

  async items(playlistId: string, viewer: string | null, page: PageQuery) {
    const rows = await this.db.query(
      `SELECT pi.id AS item_id, pi.position, pi.added_at, pi.track_id AS item_track, pi.video_id AS item_video,
              tq.*, vq.video_json
       FROM playlist_items pi
       LEFT JOIN LATERAL (SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.id = pi.track_id) tq ON true
       LEFT JOIN LATERAL (SELECT row_to_json(x) AS video_json FROM (SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.id = pi.video_id) x) vq ON true
       WHERE pi.playlist_id = $2
       ORDER BY pi.position LIMIT $3 OFFSET $4`,
      [viewer, playlistId, page.limit + 1, page.offset],
    );
    return toPage(
      rows.map((r) => ({
        itemId: r.item_id,
        position: r.position,
        addedAt: r.added_at,
        track: r.item_track ? presentTrack({ ...r, id: r.item_track }) : null,
        video: r.item_video && r.video_json ? presentVideo(r.video_json) : null,
      })),
      page,
    );
  }

  async update(id: string, user: AuthUser, input: PlaylistInput, expectedVersion?: number) {
    return this.mutate(id, user, expectedVersion, async (client, row) => {
      if (row.owner_id !== user.id && !(row.is_editorial && hasRole(user, 'editor'))) {
        throw forbidden('Only the owner can change playlist details');
      }
      await this.db.query(
        `UPDATE playlists SET title = coalesce($2, title), description = CASE WHEN $3::boolean THEN $4 ELSE description END,
           visibility = coalesce($5, visibility), is_collaborative = coalesce($6, is_collaborative)
         WHERE id = $1`,
        [id, input.title?.trim() ?? null, input.description !== undefined, input.description?.trim() || null, input.visibility ?? null, input.isCollaborative ?? null],
        client,
      );
    });
  }

  async remove(id: string, user: AuthUser) {
    const row = await this.load(id, user);
    if (row.owner_id !== user.id && !(row.is_editorial && hasRole(user, 'editor'))) throw forbidden('Only the owner can delete a playlist');
    await this.db.query('DELETE FROM playlists WHERE id = $1', [id]);
    await this.audit.record({ actorId: user.id, action: 'playlist.delete', targetType: 'playlist', targetId: id });
  }

  async addItems(id: string, user: AuthUser, trackIds: string[], videoIds: string[], position: number | undefined, expectedVersion?: number) {
    if (trackIds.length + videoIds.length === 0) throw badRequest('empty', 'Provide trackIds or videoIds');
    return this.mutate(id, user, expectedVersion, async (client) => {
      const found = await this.db.one(
        `SELECT (SELECT count(*)::int FROM tracks WHERE id = ANY($1::uuid[]) AND status = 'ready') AS t,
                (SELECT count(*)::int FROM videos WHERE id = ANY($2::uuid[]) AND status = 'ready') AS v,
                (SELECT count(*)::int FROM playlist_items WHERE playlist_id = $3) AS existing`,
        [trackIds, videoIds, id],
        client,
      );
      if (found.t !== new Set(trackIds).size || found.v !== new Set(videoIds).size) throw notFound('One or more items');
      const total = found.existing + trackIds.length + videoIds.length;
      if (total > MAX_ITEMS) throw badRequest('playlist_full', `Playlists can hold at most ${MAX_ITEMS} items`);
      const insertAt = position === undefined ? found.existing : Math.max(0, Math.min(position, found.existing));
      const count = trackIds.length + videoIds.length;
      // The (playlist_id, position) unique constraint is deferred, so shifting rows in one statement is safe.
      await this.db.query('UPDATE playlist_items SET position = position + $3 WHERE playlist_id = $1 AND position >= $2', [id, insertAt, count], client);
      await this.db.query(
        `INSERT INTO playlist_items (playlist_id, track_id, video_id, position, added_by)
         SELECT $1, x.track_id, x.video_id, $2 + x.ord - 1, $3
         FROM (
           SELECT track_id, NULL::uuid AS video_id, ord FROM unnest($4::uuid[]) WITH ORDINALITY AS a(track_id, ord)
           UNION ALL
           SELECT NULL::uuid, video_id, ord + cardinality($4::uuid[]) FROM unnest($5::uuid[]) WITH ORDINALITY AS b(video_id, ord)
         ) x`,
        [id, insertAt, user.id, trackIds, videoIds],
        client,
      );
    });
  }

  async removeItems(id: string, user: AuthUser, itemIds: string[], expectedVersion?: number) {
    return this.mutate(id, user, expectedVersion, async (client) => {
      await this.db.query('DELETE FROM playlist_items WHERE playlist_id = $1 AND id = ANY($2::uuid[])', [id, itemIds], client);
      await this.renumber(id, client);
    });
  }

  /** Reorders by moving one item to a new index. */
  async moveItem(id: string, user: AuthUser, itemId: string, toIndex: number, expectedVersion?: number) {
    return this.mutate(id, user, expectedVersion, async (client) => {
      const ids = (await this.db.query('SELECT id FROM playlist_items WHERE playlist_id = $1 ORDER BY position', [id], client)).map((r) => r.id);
      const from = ids.indexOf(itemId);
      if (from < 0) throw notFound('Playlist item');
      ids.splice(from, 1);
      ids.splice(Math.max(0, Math.min(toIndex, ids.length)), 0, itemId);
      await this.applyOrder(id, ids, client);
    });
  }

  /** Replaces the complete order; `itemIds` must be a permutation of the current items. */
  async reorder(id: string, user: AuthUser, itemIds: string[], expectedVersion?: number) {
    return this.mutate(id, user, expectedVersion, async (client) => {
      const current = (await this.db.query('SELECT id FROM playlist_items WHERE playlist_id = $1', [id], client)).map((r) => r.id);
      const set = new Set(itemIds);
      if (set.size !== itemIds.length || current.length !== itemIds.length || !current.every((c) => set.has(c))) {
        throw conflict('order_mismatch', 'itemIds must contain exactly the current playlist items');
      }
      await this.applyOrder(id, itemIds, client);
    });
  }

  private async applyOrder(id: string, ids: string[], client: pg.PoolClient) {
    await this.db.query(
      `UPDATE playlist_items pi SET position = o.ord - 1
       FROM unnest($2::uuid[]) WITH ORDINALITY AS o(id, ord) WHERE pi.id = o.id AND pi.playlist_id = $1`,
      [id, ids],
      client,
    );
  }

  private async renumber(id: string, client: pg.PoolClient) {
    await this.db.query(
      `UPDATE playlist_items pi SET position = r.rn - 1
       FROM (SELECT id, row_number() OVER (ORDER BY position) AS rn FROM playlist_items WHERE playlist_id = $1) r
       WHERE pi.id = r.id`,
      [id],
      client,
    );
  }

  /**
   * Serialises edits on one playlist (row lock), checks permission and optional optimistic concurrency
   * (`expectedVersion`), then bumps the version so other devices notice the change.
   */
  private async mutate(id: string, user: AuthUser, expectedVersion: number | undefined, fn: (client: pg.PoolClient, row: any) => Promise<void>) {
    await this.db.tx(async (client) => {
      await this.db.query('SELECT id FROM playlists WHERE id = $1 FOR UPDATE', [id], client);
      const row = await this.load(id, user, client);
      if (!this.canEdit(row, user)) throw forbidden('You cannot edit this playlist');
      if (expectedVersion !== undefined && row.version !== expectedVersion) {
        throw conflict('version_conflict', 'Playlist was changed on another device', { currentVersion: row.version });
      }
      await fn(client, row);
      await this.db.query('UPDATE playlists SET version = version + 1 WHERE id = $1', [id], client);
    });
    return this.get(id, user);
  }

  async addCollaborator(id: string, owner: AuthUser, email: string) {
    const row = await this.load(id, owner);
    if (row.owner_id !== owner.id) throw forbidden('Only the owner can invite collaborators');
    if (!row.is_collaborative) throw badRequest('not_collaborative', 'Enable collaboration on this playlist first');
    const target = await this.db.one('SELECT id FROM users WHERE email = $1 AND disabled_at IS NULL', [email]);
    if (!target) throw notFound('User');
    await this.db.query('INSERT INTO playlist_collaborators (playlist_id, user_id) VALUES ($1, $2) ON CONFLICT DO NOTHING', [id, target.id]);
    return { playlistId: id, userId: target.id };
  }

  async removeCollaborator(id: string, owner: AuthUser, userId: string) {
    const row = await this.load(id, owner);
    if (row.owner_id !== owner.id && owner.id !== userId) throw forbidden();
    await this.db.query('DELETE FROM playlist_collaborators WHERE playlist_id = $1 AND user_id = $2', [id, userId]);
  }

  async editorial(page: PageQuery) {
    const rows = await this.db.query(
      `SELECT ${playlistSelect('NULL')} FROM ${playlistFrom} WHERE p.is_editorial OR p.visibility = 'public'
       ORDER BY p.is_editorial DESC, p.updated_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset],
    );
    return toPage(rows.map((r) => presentPlaylist(r)), page);
  }
}
