import { Injectable } from '@nestjs/common';
import { toPage, type PageQuery } from '../common/pagination.js';
import { notFound } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { parseLrc } from '../lyrics/lrc.js';
import {
  albumFrom,
  albumSelect,
  artistSelect,
  presentAlbum,
  presentArtist,
  presentTrack,
  presentVideo,
  trackFrom,
  trackSelect,
  videoFrom,
  videoSelect,
} from './presenters.js';

@Injectable()
export class CatalogService {
  constructor(private readonly db: DbService) {}

  async tracksByIds(ids: string[], viewer: string | null) {
    if (ids.length === 0) return [];
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.id = ANY($2::uuid[]) AND t.status = 'ready'`,
      [viewer, ids],
    );
    const byId = new Map(rows.map((r) => [r.id, presentTrack(r)]));
    return ids.map((id) => byId.get(id)).filter((t): t is NonNullable<typeof t> => !!t);
  }

  async track(id: string, viewer: string | null) {
    const row = await this.db.one(`SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.id = $2 AND t.status = 'ready'`, [viewer, id]);
    if (!row) throw notFound('Track');
    return presentTrack(row);
  }

  async lyrics(trackId: string) {
    const row = await this.db.one('SELECT * FROM lyrics WHERE track_id = $1', [trackId]);
    if (!row) throw notFound('Lyrics');
    const parsed = parseLrc(row.content);
    return {
      trackId,
      synced: row.kind === 'synced' && parsed.synced,
      language: row.language,
      lines: parsed.lines,
      attribution: { source: row.source, license: row.license_note },
      updatedAt: row.updated_at,
    };
  }

  async artist(id: string, viewer: string | null) {
    const row = await this.db.one(
      `SELECT ${artistSelect},
         (SELECT count(*) FROM followed_artists f WHERE f.artist_id = ar.id) AS follower_count,
         ($1::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM followed_artists f WHERE f.artist_id = ar.id AND f.user_id = $1::uuid)) AS is_followed
       FROM artists ar WHERE ar.id = $2`,
      [viewer, id],
    );
    if (!row) throw notFound('Artist');
    const [topTracks, albums, videos, related] = await Promise.all([
      this.db.query(
        `SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.artist_id = $2 AND t.status = 'ready'
         ORDER BY t.play_count DESC, t.created_at DESC LIMIT 10`,
        [viewer, id],
      ),
      this.db.query(`SELECT ${albumSelect} FROM ${albumFrom} WHERE al.artist_id = $1 ORDER BY al.release_date DESC NULLS LAST, al.title`, [id]),
      this.db.query(
        `SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.artist_id = $2 AND v.status = 'ready' ORDER BY v.created_at DESC LIMIT 20`,
        [viewer, id],
      ),
      this.relatedArtists(id, 12),
    ]);
    const releases = albums.map(presentAlbum);
    return {
      artist: presentArtist(row),
      topTracks: topTracks.map(presentTrack),
      releases: {
        albums: releases.filter((a) => a.albumType === 'album'),
        singles: releases.filter((a) => a.albumType === 'single' || a.albumType === 'ep'),
        compilations: releases.filter((a) => a.albumType === 'compilation'),
      },
      videos: videos.map(presentVideo),
      related,
    };
  }

  /**
   * Related artists, explainable: artists sharing genres with this artist, boosted by listeners in common
   * (users who played both in the last 90 days).
   */
  async relatedArtists(id: string, limit: number) {
    const rows = await this.db.query(
      `WITH me AS (
         SELECT coalesce(nullif(ar.genres, '{}'), (SELECT coalesce(array_agg(DISTINCT g), '{}') FROM tracks t, unnest(t.genres) g WHERE t.artist_id = ar.id)) AS genres
         FROM artists ar WHERE ar.id = $1
       ), listeners AS (
         SELECT DISTINCT pe.user_id FROM playback_events pe JOIN tracks t ON t.id = pe.track_id
         WHERE t.artist_id = $1 AND pe.played_at > now() - interval '90 days'
       ), co AS (
         SELECT t.artist_id, count(DISTINCT pe.user_id) AS shared FROM playback_events pe JOIN tracks t ON t.id = pe.track_id
         WHERE pe.user_id IN (SELECT user_id FROM listeners) AND t.artist_id <> $1 AND pe.played_at > now() - interval '90 days'
         GROUP BY t.artist_id
       ), g AS (
         SELECT t.artist_id, count(DISTINCT x) AS shared_genres FROM tracks t, unnest(t.genres) x, me
         WHERE x = ANY(me.genres) AND t.artist_id <> $1 GROUP BY t.artist_id
       )
       SELECT ${artistSelect}, coalesce(g.shared_genres, 0) * 2 + coalesce(co.shared, 0) * 3 AS score
       FROM artists ar LEFT JOIN g ON g.artist_id = ar.id LEFT JOIN co ON co.artist_id = ar.id
       WHERE ar.id <> $1 AND (g.artist_id IS NOT NULL OR co.artist_id IS NOT NULL)
       ORDER BY score DESC, ar.name LIMIT $2`,
      [id, limit],
    );
    return rows.map(presentArtist);
  }

  async artistTracks(id: string, viewer: string | null, page: PageQuery) {
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.artist_id = $2 AND t.status = 'ready'
       ORDER BY al.release_date DESC NULLS LAST, t.album_id, t.disc_number, t.track_number LIMIT $3 OFFSET $4`,
      [viewer, id, page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentTrack), page);
  }

  async album(id: string, viewer: string | null) {
    const row = await this.db.one(
      `SELECT ${albumSelect},
        ($1::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM saved_albums s WHERE s.album_id = al.id AND s.user_id = $1::uuid)) AS is_saved
       FROM ${albumFrom} WHERE al.id = $2`,
      [viewer, id],
    );
    if (!row) throw notFound('Album');
    const [tracks, more, related] = await Promise.all([
      this.db.query(
        `SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.album_id = $2 AND t.status = 'ready'
         ORDER BY t.disc_number, t.track_number NULLS LAST, t.title`,
        [viewer, id],
      ),
      this.db.query(
        `SELECT ${albumSelect} FROM ${albumFrom} WHERE al.artist_id = $1 AND al.id <> $2 ORDER BY al.release_date DESC NULLS LAST LIMIT 10`,
        [row.artist_id, id],
      ),
      this.db.query(
        `SELECT ${albumSelect} FROM ${albumFrom} WHERE al.id <> $1 AND al.artist_id <> $2 AND al.genres && $3::text[]
         ORDER BY al.release_date DESC NULLS LAST LIMIT 10`,
        [id, row.artist_id, row.genres?.length ? row.genres : ['__none__']],
      ),
    ]);
    return {
      album: presentAlbum(row),
      tracks: tracks.map(presentTrack),
      moreByArtist: more.map(presentAlbum),
      related: related.map(presentAlbum),
    };
  }

  async albums(page: PageQuery, sort: 'recent' | 'title' = 'recent') {
    const order = sort === 'title' ? 'al.title' : 'al.created_at DESC';
    const rows = await this.db.query(
      `SELECT ${albumSelect} FROM ${albumFrom} WHERE EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = al.id AND t.status = 'ready')
       ORDER BY ${order} LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentAlbum), page);
  }

  async artists(page: PageQuery) {
    const rows = await this.db.query(
      `SELECT ${artistSelect} FROM artists ar WHERE EXISTS (SELECT 1 FROM tracks t WHERE t.artist_id = ar.id AND t.status = 'ready')
       ORDER BY coalesce(ar.sort_name, ar.name) LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentArtist), page);
  }

  async videos(viewer: string | null, page: PageQuery, genre?: string) {
    const rows = await this.db.query(
      `SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.status = 'ready' AND ($4::text IS NULL OR $4 = ANY(v.genres))
       ORDER BY v.created_at DESC LIMIT $2 OFFSET $3`,
      [viewer, page.limit + 1, page.offset, genre ?? null],
    );
    return toPage(rows.map(presentVideo), page);
  }

  async video(id: string, viewer: string | null) {
    const row = await this.db.one(`SELECT ${videoSelect('$1')} FROM ${videoFrom} WHERE v.id = $2 AND v.status = 'ready'`, [viewer, id]);
    if (!row) throw notFound('Video');
    // "Up next": same artist first, then overlapping genres, then newest.
    const related = await this.db.query(
      `SELECT ${videoSelect('$1')} FROM ${videoFrom}
       WHERE v.status = 'ready' AND v.id <> $2
       ORDER BY (v.artist_id IS NOT DISTINCT FROM $3::uuid AND $3::uuid IS NOT NULL) DESC, (v.genres && $4::text[]) DESC, v.created_at DESC
       LIMIT 15`,
      [viewer, id, row.artist_id, row.genres ?? []],
    );
    return { video: presentVideo(row), related: related.map(presentVideo) };
  }

  async genres() {
    const [genres, moods] = await Promise.all([
      this.db.query(
        `SELECT g AS name, count(*)::int AS track_count FROM tracks t, unnest(t.genres) g WHERE t.status = 'ready'
         GROUP BY g ORDER BY track_count DESC, g LIMIT 100`,
      ),
      this.db.query(
        `SELECT m AS name, count(*)::int AS track_count FROM tracks t, unnest(t.moods) m WHERE t.status = 'ready'
         GROUP BY m ORDER BY track_count DESC, m LIMIT 100`,
      ),
    ]);
    return {
      genres: genres.map((g) => ({ name: g.name, trackCount: g.track_count })),
      moods: moods.map((m) => ({ name: m.name, trackCount: m.track_count })),
    };
  }

  async tracksByTag(kind: 'genre' | 'mood', value: string, viewer: string | null, page: PageQuery) {
    const column = kind === 'genre' ? 't.genres' : 't.moods';
    const rows = await this.db.query(
      `SELECT ${trackSelect('$1')} FROM ${trackFrom} WHERE t.status = 'ready' AND $2 = ANY(${column})
       ORDER BY t.play_count DESC, t.created_at DESC LIMIT $3 OFFSET $4`,
      [viewer, value, page.limit + 1, page.offset],
    );
    return toPage(rows.map(presentTrack), page);
  }
}
