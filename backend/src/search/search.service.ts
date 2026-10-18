import { Injectable } from '@nestjs/common';
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
import { toPage, type PageQuery } from '../common/pagination.js';
import { DbService } from '../db/db.service.js';

export const SEARCH_TYPES = ['tracks', 'artists', 'albums', 'playlists', 'videos', 'genres'] as const;
export type SearchType = (typeof SEARCH_TYPES)[number];

/**
 * Converts free text into a prefix tsquery: "daft pun" -> "daft:* & pun:*".
 * Only letters/digits survive, so user input can never inject tsquery operators.
 */
export function toPrefixQuery(q: string): string | null {
  const words = q
    .toLowerCase()
    .normalize('NFKC')
    .split(/[^\p{L}\p{N}]+/u)
    .filter((w) => w.length > 0)
    .slice(0, 8);
  return words.length ? words.map((w) => `${w}:*`).join(' & ') : null;
}

/**
 * Postgres full-text search (prefix matching on GIN tsvector indexes) blended with trigram similarity
 * for typo tolerance. The service boundary allows swapping in a dedicated engine (OpenSearch/Meilisearch)
 * later without changing the API contract.
 */
@Injectable()
export class SearchService {
  constructor(private readonly db: DbService) {}

  async search(q: string, types: SearchType[], viewer: string, page: PageQuery) {
    const query = q.trim().slice(0, 200);
    const tsq = toPrefixQuery(query);
    if (!tsq) return { query, results: {} };
    const single = types.length === 1;
    const lim = single ? page : { limit: Math.min(page.limit, 10), offset: 0 };
    const results: Record<string, unknown> = {};
    const tasks: Promise<void>[] = [];
    const rank = (alias: string, col: string) =>
      `(ts_rank(${alias}.search, to_tsquery('simple', $2)) * 2 + similarity(${col}, $3) + CASE WHEN lower(${col}) = lower($3) THEN 2 ELSE 0 END)`;
    const match = (alias: string, col: string) => `(${alias}.search @@ to_tsquery('simple', $2) OR ${col} % $3)`;

    if (types.includes('tracks'))
      tasks.push(
        this.db
          .query(
            `SELECT ${trackSelect('$1')} FROM ${trackFrom}
             WHERE t.status = 'ready' AND (${match('t', 't.title')} OR ar.search @@ to_tsquery('simple', $2))
             ORDER BY ${rank('t', 't.title')} + CASE WHEN ar.search @@ to_tsquery('simple', $2) THEN 0.5 ELSE 0 END DESC, t.play_count DESC
             LIMIT $4 OFFSET $5`,
            [viewer, tsq, query, lim.limit + 1, lim.offset],
          )
          .then((rows) => void (results.tracks = toPage(rows.map(presentTrack), lim))),
      );
    if (types.includes('artists'))
      tasks.push(
        this.db
          .query(
            `SELECT ${artistSelect},
               ($1::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM followed_artists f WHERE f.artist_id = ar.id AND f.user_id = $1)) AS is_followed
             FROM artists ar WHERE ${match('ar', 'ar.name')}
             ORDER BY ${rank('ar', 'ar.name')} DESC LIMIT $4 OFFSET $5`,
            [viewer, tsq, query, lim.limit + 1, lim.offset],
          )
          .then((rows) => void (results.artists = toPage(rows.map(presentArtist), lim))),
      );
    if (types.includes('albums'))
      tasks.push(
        this.db
          .query(
            `SELECT ${albumSelect},
               ($1::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM saved_albums s WHERE s.album_id = al.id AND s.user_id = $1)) AS is_saved
             FROM ${albumFrom} WHERE (${match('al', 'al.title')} OR ar.search @@ to_tsquery('simple', $2))
             ORDER BY ${rank('al', 'al.title')} DESC LIMIT $4 OFFSET $5`,
            [viewer, tsq, query, lim.limit + 1, lim.offset],
          )
          .then((rows) => void (results.albums = toPage(rows.map(presentAlbum), lim))),
      );
    if (types.includes('playlists'))
      tasks.push(
        this.db
          .query(
            `SELECT ${playlistSelect('$1')} FROM ${playlistFrom}
             WHERE (p.visibility = 'public' OR p.is_editorial OR p.owner_id = $1) AND ${match('p', 'p.title')}
             ORDER BY ${rank('p', 'p.title')} DESC LIMIT $4 OFFSET $5`,
            [viewer, tsq, query, lim.limit + 1, lim.offset],
          )
          .then((rows) => void (results.playlists = toPage(rows.map((r) => presentPlaylist(r, viewer)), lim))),
      );
    if (types.includes('videos'))
      tasks.push(
        this.db
          .query(
            `SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.status = 'ready' AND ${match('v', 'v.title')}
             ORDER BY ${rank('v', 'v.title')} DESC LIMIT $4 OFFSET $5`,
            [viewer, tsq, query, lim.limit + 1, lim.offset],
          )
          .then((rows) => void (results.videos = toPage(rows.map(presentVideo), lim))),
      );
    if (types.includes('genres'))
      tasks.push(
        this.db
          .query(
            `SELECT name, kind, count(*)::int AS track_count FROM (
               SELECT g AS name, 'genre' AS kind FROM tracks, unnest(genres) g WHERE status = 'ready'
               UNION ALL SELECT m, 'mood' FROM tracks, unnest(moods) m WHERE status = 'ready') x
             WHERE name ILIKE $1 || '%' OR similarity(name, $1) > 0.3
             GROUP BY name, kind ORDER BY track_count DESC LIMIT 10`,
            [query],
          )
          .then((rows) => void (results.genres = { items: rows.map((r) => ({ name: r.name, kind: r.kind, trackCount: r.track_count })) })),
      );
    await Promise.all(tasks);
    return { query, results };
  }

  async suggest(q: string) {
    const query = q.trim().slice(0, 100);
    if (!query) return { items: [] };
    const rows = await this.db.query(
      `SELECT text, type, id FROM (
         SELECT name AS text, 'artist' AS type, id, similarity(name, $1) + CASE WHEN name ILIKE $1 || '%' THEN 1 ELSE 0 END AS score
           FROM artists WHERE name ILIKE $1 || '%' OR name % $1
         UNION ALL
         SELECT title, 'track', id, similarity(title, $1) + CASE WHEN title ILIKE $1 || '%' THEN 1 ELSE 0 END + least(play_count, 1000) / 2000.0
           FROM tracks WHERE status = 'ready' AND (title ILIKE $1 || '%' OR title % $1)
         UNION ALL
         SELECT title, 'album', id, similarity(title, $1) + CASE WHEN title ILIKE $1 || '%' THEN 1 ELSE 0 END
           FROM albums WHERE title ILIKE $1 || '%' OR title % $1
         UNION ALL
         SELECT title, 'video', id, similarity(title, $1) + CASE WHEN title ILIKE $1 || '%' THEN 1 ELSE 0 END
           FROM videos WHERE status = 'ready' AND (title ILIKE $1 || '%' OR title % $1)
       ) s ORDER BY score DESC LIMIT 8`,
      [escapeLike(query)],
    );
    return { items: rows };
  }

  async recent(userId: string) {
    const rows = await this.db.query('SELECT query, created_at FROM recent_searches WHERE user_id = $1 ORDER BY created_at DESC LIMIT 20', [userId]);
    return { items: rows.map((r) => ({ query: r.query, at: r.created_at })) };
  }

  async addRecent(userId: string, query: string) {
    const q = query.trim().slice(0, 200);
    if (!q) return;
    await this.db.query(
      `INSERT INTO recent_searches (user_id, query) VALUES ($1, $2) ON CONFLICT (user_id, query) DO UPDATE SET created_at = now()`,
      [userId, q],
    );
    await this.db.query(
      `DELETE FROM recent_searches WHERE user_id = $1 AND query NOT IN
         (SELECT query FROM recent_searches WHERE user_id = $1 ORDER BY created_at DESC LIMIT 50)`,
      [userId],
    );
  }

  async clearRecent(userId: string, query?: string) {
    if (query) await this.db.query('DELETE FROM recent_searches WHERE user_id = $1 AND query = $2', [userId, query]);
    else await this.db.query('DELETE FROM recent_searches WHERE user_id = $1', [userId]);
  }
}

const escapeLike = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);
