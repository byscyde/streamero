import { Injectable } from '@nestjs/common';
import type pg from 'pg';
import { notFound } from '../common/errors.js';
import { toPage, type PageQuery } from '../common/pagination.js';
import {
  albumFrom,
  albumSelect,
  artistSelect,
  playlistFrom,
  playlistSelect,
  presentAlbum,
  presentArtist,
  presentPlaylist,
  presentTrack,
  presentVideo,
  trackFrom,
  trackSelect,
  videoFrom,
  videoSelect,
} from '../catalog/presenters.js';
import { DbService } from '../db/db.service.js';

export type LibraryItemType = 'track' | 'album' | 'artist' | 'video' | 'playlist';

const TABLES: Record<LibraryItemType, { table: string; column: string; target: string }> = {
  track: { table: 'liked_tracks', column: 'track_id', target: 'tracks' },
  album: { table: 'saved_albums', column: 'album_id', target: 'albums' },
  artist: { table: 'followed_artists', column: 'artist_id', target: 'artists' },
  video: { table: 'liked_videos', column: 'video_id', target: 'videos' },
  playlist: { table: 'saved_playlists', column: 'playlist_id', target: 'playlists' },
};

export interface LibraryChange {
  type: LibraryItemType;
  id: string;
  op: 'add' | 'remove';
  at: string;
}

export type LibrarySort = 'recent' | 'title' | 'artist';

@Injectable()
export class LibraryService {
  constructor(private readonly db: DbService) {}

  /**
   * Applies one change with last-write-wins semantics against `at`:
   * an add older than a later removal is ignored, and a removal older than a later add is ignored.
   */
  async apply(userId: string, change: LibraryChange, client?: pg.PoolClient): Promise<boolean> {
    const t = TABLES[change.type];
    const at = new Date(change.at);
    const when = Number.isNaN(at.getTime()) || at.getTime() > Date.now() + 60_000 ? new Date() : at;
    if (change.op === 'add') {
      if (change.type === 'playlist') await this.assertPlaylistVisible(userId, change.id, client);
      const exists = await this.db.one(`SELECT 1 AS ok FROM ${t.target} WHERE id = $1`, [change.id], client);
      if (!exists) throw notFound(change.type);
      const res = await this.db.query(
        `WITH tomb AS (SELECT removed_at FROM library_removals WHERE user_id = $1 AND item_type = $3 AND item_id = $2)
         INSERT INTO ${t.table} (user_id, ${t.column}, created_at)
         SELECT $1, $2, $4 WHERE NOT EXISTS (SELECT 1 FROM tomb WHERE removed_at > $4)
         ON CONFLICT DO NOTHING RETURNING 1 AS ok`,
        [userId, change.id, change.type, when],
        client,
      );
      if (res.length) await this.db.query('DELETE FROM library_removals WHERE user_id = $1 AND item_type = $2 AND item_id = $3', [userId, change.type, change.id], client);
      return res.length > 0;
    }
    const res = await this.db.query(
      `DELETE FROM ${t.table} WHERE user_id = $1 AND ${t.column} = $2 AND created_at <= $3 RETURNING 1 AS ok`,
      [userId, change.id, when],
      client,
    );
    // Record a tombstone unless a newer add (from another device) is still present.
    await this.db.query(
      `INSERT INTO library_removals (user_id, item_type, item_id, removed_at)
       SELECT $1, $2, $3, $4 WHERE NOT EXISTS (SELECT 1 FROM ${t.table} WHERE user_id = $1 AND ${t.column} = $3)
       ON CONFLICT (user_id, item_type, item_id) DO UPDATE SET removed_at = greatest(library_removals.removed_at, EXCLUDED.removed_at)`,
      [userId, change.type, change.id, when],
      client,
    );
    return res.length > 0;
  }

  private async assertPlaylistVisible(userId: string, id: string, client?: pg.PoolClient) {
    const p = await this.db.one(
      `SELECT 1 AS ok FROM playlists WHERE id = $1 AND (visibility <> 'private' OR owner_id = $2 OR is_editorial)`,
      [id, userId],
      client,
    );
    if (!p) throw notFound('playlist');
  }

  async set(userId: string, type: LibraryItemType, id: string, saved: boolean) {
    await this.apply(userId, { type, id, op: saved ? 'add' : 'remove', at: new Date().toISOString() });
    return { type, id, saved };
  }

  async sync(userId: string, changes: LibraryChange[]) {
    const sorted = [...changes].sort((a, b) => Date.parse(a.at) - Date.parse(b.at));
    const results: { type: LibraryItemType; id: string; op: string; applied: boolean; error?: string }[] = [];
    for (const c of sorted) {
      try {
        const applied = await this.db.tx((client) => this.apply(userId, c, client));
        results.push({ type: c.type, id: c.id, op: c.op, applied });
      } catch (err: any) {
        results.push({ type: c.type, id: c.id, op: c.op, applied: false, error: err?.response?.code ?? 'failed' });
      }
    }
    return { results, serverTime: new Date().toISOString() };
  }

  /** Delta feed for multi-device sync: everything added or removed since `since`. */
  async changes(userId: string, since: Date) {
    const added = await this.db.query(
      `SELECT 'track' AS type, track_id AS id, created_at AS at FROM liked_tracks WHERE user_id = $1 AND created_at > $2
       UNION ALL SELECT 'album', album_id, created_at FROM saved_albums WHERE user_id = $1 AND created_at > $2
       UNION ALL SELECT 'artist', artist_id, created_at FROM followed_artists WHERE user_id = $1 AND created_at > $2
       UNION ALL SELECT 'video', video_id, created_at FROM liked_videos WHERE user_id = $1 AND created_at > $2
       UNION ALL SELECT 'playlist', playlist_id, created_at FROM saved_playlists WHERE user_id = $1 AND created_at > $2
       ORDER BY at LIMIT 5000`,
      [userId, since],
    );
    const removed = await this.db.query(
      `SELECT item_type AS type, item_id AS id, removed_at AS at FROM library_removals
       WHERE user_id = $1 AND removed_at > $2 ORDER BY removed_at LIMIT 5000`,
      [userId, since],
    );
    return { added, removed, serverTime: new Date().toISOString() };
  }

  async ids(userId: string) {
    const r = await this.db.one(
      `SELECT
        (SELECT coalesce(array_agg(track_id), '{}') FROM liked_tracks WHERE user_id = $1) AS tracks,
        (SELECT coalesce(array_agg(album_id), '{}') FROM saved_albums WHERE user_id = $1) AS albums,
        (SELECT coalesce(array_agg(artist_id), '{}') FROM followed_artists WHERE user_id = $1) AS artists,
        (SELECT coalesce(array_agg(video_id), '{}') FROM liked_videos WHERE user_id = $1) AS videos,
        (SELECT coalesce(array_agg(playlist_id), '{}') FROM saved_playlists WHERE user_id = $1) AS playlists`,
      [userId],
    );
    return { ...r, serverTime: new Date().toISOString() };
  }

  async likedTracks(userId: string, page: PageQuery, sort: LibrarySort, filter?: string) {
    const order = { recent: 'lt.created_at DESC', title: 'lower(t.title)', artist: 'lower(ar.name), lower(t.title)' }[sort];
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')}, lt.created_at AS liked_at, count(*) OVER () AS total
       FROM liked_tracks lt JOIN ${trackFrom} ON t.id = lt.track_id
       WHERE lt.user_id = $1 AND t.status = 'ready'
         AND ($4::text IS NULL OR t.title ILIKE '%' || $4 || '%' OR ar.name ILIKE '%' || $4 || '%' OR al.title ILIKE '%' || $4 || '%')
       ORDER BY ${order} LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset, filter || null],
    );
    return toPage(rows.map((r) => ({ ...presentTrack(r), addedAt: r.liked_at })), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async savedAlbums(userId: string, page: PageQuery, sort: LibrarySort) {
    const order = { recent: 's.created_at DESC', title: 'lower(al.title)', artist: 'lower(ar.name), al.release_date DESC' }[sort];
    const rows = await this.db.query(
      `SELECT ${albumSelect}, true AS is_saved, s.created_at AS saved_at FROM saved_albums s JOIN ${albumFrom} ON al.id = s.album_id
       WHERE s.user_id = $1 ORDER BY ${order} LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(rows.map((r) => ({ ...presentAlbum(r), addedAt: r.saved_at })), page);
  }

  async followedArtists(userId: string, page: PageQuery, sort: LibrarySort) {
    const order = sort === 'recent' ? 'f.created_at DESC' : 'lower(ar.name)';
    const rows = await this.db.query(
      `SELECT ${artistSelect}, true AS is_followed FROM followed_artists f JOIN artists ar ON ar.id = f.artist_id
       WHERE f.user_id = $1 ORDER BY ${order} LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentArtist), page);
  }

  async likedVideos(userId: string, page: PageQuery) {
    const rows = await this.db.query(
      `SELECT ${videoSelect('$1')} FROM liked_videos lv JOIN ${videoFrom} ON v.id = lv.video_id
       WHERE lv.user_id = $1 AND v.status = 'ready' ORDER BY lv.created_at DESC LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentVideo), page);
  }

  /** Owned, collaborative and saved playlists in one list. */
  async playlists(userId: string, page: PageQuery, sort: LibrarySort) {
    const order = sort === 'title' ? 'lower(p.title)' : 'p.updated_at DESC';
    const rows = await this.db.query(
      `SELECT ${playlistSelect('$1')} FROM ${playlistFrom}
       WHERE p.owner_id = $1
          OR EXISTS (SELECT 1 FROM playlist_collaborators pc WHERE pc.playlist_id = p.id AND pc.user_id = $1)
          OR EXISTS (SELECT 1 FROM saved_playlists sp WHERE sp.playlist_id = p.id AND sp.user_id = $1)
       ORDER BY ${order} LIMIT $2 OFFSET $3`,
      [userId, page.limit + 1, page.offset],
    );
    return toPage(rows.map((r) => presentPlaylist(r, userId)), page);
  }

  async summary(userId: string) {
    return this.db.one(
      `SELECT
        (SELECT count(*)::int FROM liked_tracks WHERE user_id = $1) AS "likedTracks",
        (SELECT count(*)::int FROM saved_albums WHERE user_id = $1) AS "albums",
        (SELECT count(*)::int FROM followed_artists WHERE user_id = $1) AS "artists",
        (SELECT count(*)::int FROM liked_videos WHERE user_id = $1) AS "likedVideos",
        (SELECT count(*)::int FROM playlists WHERE owner_id = $1) AS "ownPlaylists",
        (SELECT count(*)::int FROM saved_playlists WHERE user_id = $1) AS "savedPlaylists",
        (SELECT count(*)::int FROM download_grants WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()) AS "downloads"`,
      [userId],
    );
  }
}
