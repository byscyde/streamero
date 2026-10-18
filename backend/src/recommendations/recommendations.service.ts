import { Injectable } from '@nestjs/common';
import { albumFrom, albumSelect, artistSelect, presentAlbum, presentArtist, presentTrack, trackFrom, trackSelect } from '../catalog/presenters.js';
import { notFound } from '../common/errors.js';
import { DbService } from '../db/db.service.js';

/**
 * Explainable, rule-based recommendations over the real catalog. Every score is a weighted sum of
 * signals that can be shown to the user ("Because you like Indie", "Popular this week").
 * This is intentionally *not* machine learning; the service boundary lets a collaborative-filtering
 * or learned model replace `scoreTracks` later without touching callers.
 */
export const WEIGHTS = {
  likedGenre: 3,
  playedGenre: 1,
  likedArtist: 4,
  followedArtist: 5,
  playedArtist: 2,
  mood: 1,
  popularity: 1.5,
  freshness: 1,
  recentlyPlayedPenalty: -6,
} as const;

export interface Taste {
  genres: Map<string, number>;
  moods: Map<string, number>;
  artists: Map<string, number>;
  allowExplicit: boolean;
  personalized: boolean;
}

export interface MixDescriptor {
  id: string;
  kind: 'genre' | 'artist' | 'discovery' | 'mood';
  title: string;
  description: string;
  seed: string;
}

@Injectable()
export class RecommendationsService {
  constructor(private readonly db: DbService) {}

  async taste(userId: string): Promise<Taste> {
    const user = await this.db.one('SELECT allow_explicit, personalization_enabled FROM users WHERE id = $1', [userId]);
    const taste: Taste = {
      genres: new Map(),
      moods: new Map(),
      artists: new Map(),
      allowExplicit: user?.allow_explicit ?? true,
      personalized: user?.personalization_enabled ?? true,
    };
    if (!taste.personalized) return taste;
    const signals = await this.db.query(
      `SELECT 'liked' AS src, t.artist_id, t.genres, t.moods, 1::float AS w FROM liked_tracks lt JOIN tracks t ON t.id = lt.track_id WHERE lt.user_id = $1
       UNION ALL
       SELECT 'played', t.artist_id, t.genres, t.moods,
              -- exponential decay with a 30 day half-life
              power(0.5, extract(epoch FROM now() - pe.played_at) / (86400 * 30))::float
       FROM playback_events pe JOIN tracks t ON t.id = pe.track_id
       WHERE pe.user_id = $1 AND pe.played_at > now() - interval '180 days'
       UNION ALL
       SELECT 'followed', f.artist_id, ar.genres, '{}'::text[], 1 FROM followed_artists f JOIN artists ar ON ar.id = f.artist_id WHERE f.user_id = $1
       UNION ALL
       SELECT 'saved_album', al.artist_id, al.genres, '{}'::text[], 1 FROM saved_albums s JOIN albums al ON al.id = s.album_id WHERE s.user_id = $1`,
      [userId],
    );
    const add = (m: Map<string, number>, k: string, v: number) => m.set(k, (m.get(k) ?? 0) + v);
    for (const s of signals) {
      const gw = s.src === 'liked' ? WEIGHTS.likedGenre : s.src === 'played' ? WEIGHTS.playedGenre : 2;
      const aw = s.src === 'liked' ? WEIGHTS.likedArtist : s.src === 'followed' ? WEIGHTS.followedArtist : s.src === 'played' ? WEIGHTS.playedArtist : 2;
      for (const g of s.genres ?? []) add(taste.genres, g, gw * s.w);
      for (const m of s.moods ?? []) add(taste.moods, m, WEIGHTS.mood * s.w);
      add(taste.artists, s.artist_id, aw * s.w);
    }
    return taste;
  }

  /**
   * Scores candidate tracks in SQL using the user's taste vectors. Returns tracks with reasons.
   * `scope` narrows candidates (e.g. to a genre for a mix, or excludes known artists for discovery).
   */
  async scoreTracks(
    userId: string,
    taste: Taste,
    opts: { limit: number; genre?: string; mood?: string; artistIds?: string[]; excludeArtists?: string[]; excludeLiked?: boolean } = { limit: 30 },
  ) {
    const top = <T>(m: Map<T, number>, n: number) => [...m.entries()].sort((a, b) => b[1] - a[1]).slice(0, n);
    const genres = top(taste.genres, 20);
    const moods = top(taste.moods, 10);
    const artists = top(taste.artists, 50);
    const rows = await this.db.query(
      `WITH g AS (SELECT * FROM unnest($2::text[], $3::float[]) AS x(name, w)),
            m AS (SELECT * FROM unnest($4::text[], $5::float[]) AS x(name, w)),
            a AS (SELECT * FROM unnest($6::uuid[], $7::float[]) AS x(id, w)),
            recent AS (SELECT DISTINCT track_id FROM playback_events WHERE user_id = $1 AND played_at > now() - interval '2 days' AND track_id IS NOT NULL),
            week AS (SELECT track_id, count(*) AS plays FROM playback_events WHERE played_at > now() - interval '7 days' AND track_id IS NOT NULL GROUP BY track_id)
       SELECT ${trackSelect('$1')},
         coalesce((SELECT sum(g.w) FROM g WHERE g.name = ANY(t.genres)), 0) AS s_genre,
         coalesce((SELECT sum(m.w) FROM m WHERE m.name = ANY(t.moods)), 0) AS s_mood,
         coalesce((SELECT a.w FROM a WHERE a.id = t.artist_id), 0) AS s_artist,
         ln(1 + coalesce(week.plays, 0) + t.play_count / 10.0) AS s_pop,
         CASE WHEN t.created_at > now() - interval '30 days' THEN 1 ELSE 0 END AS s_fresh,
         (t.id IN (SELECT track_id FROM recent)) AS s_recent,
         (SELECT g.name FROM g WHERE g.name = ANY(t.genres) ORDER BY g.w DESC LIMIT 1) AS top_genre
       FROM ${trackFrom} LEFT JOIN week ON week.track_id = t.id
       WHERE t.status = 'ready'
         AND ($8::boolean OR NOT t.explicit)
         AND ($9::text IS NULL OR $9 = ANY(t.genres))
         AND ($10::text IS NULL OR $10 = ANY(t.moods))
         AND ($11::uuid[] IS NULL OR t.artist_id = ANY($11::uuid[]))
         AND ($12::uuid[] IS NULL OR NOT (t.artist_id = ANY($12::uuid[])))
         AND (NOT $13::boolean OR NOT EXISTS (SELECT 1 FROM liked_tracks lt WHERE lt.user_id = $1 AND lt.track_id = t.id))
       ORDER BY random() LIMIT 2000`,
      [
        userId,
        genres.map(([k]) => k),
        genres.map(([, v]) => v),
        moods.map(([k]) => k),
        moods.map(([, v]) => v),
        artists.map(([k]) => k),
        artists.map(([, v]) => v),
        taste.allowExplicit,
        opts.genre ?? null,
        opts.mood ?? null,
        opts.artistIds ?? null,
        opts.excludeArtists ?? null,
        !!opts.excludeLiked,
      ],
    );
    const maxGenre = Math.max(1, ...rows.map((r) => Number(r.s_genre)));
    const maxArtist = Math.max(1, ...rows.map((r) => Number(r.s_artist)));
    const scored = rows.map((r) => {
      const genre = (Number(r.s_genre) / maxGenre) * WEIGHTS.likedGenre;
      const artist = (Number(r.s_artist) / maxArtist) * WEIGHTS.likedArtist;
      const mood = Math.min(1, Number(r.s_mood)) * WEIGHTS.mood;
      const pop = Math.min(1, Number(r.s_pop) / 5) * WEIGHTS.popularity;
      const fresh = Number(r.s_fresh) * WEIGHTS.freshness;
      const penalty = r.s_recent ? WEIGHTS.recentlyPlayedPenalty : 0;
      const score = genre + artist + mood + pop + fresh + penalty;
      const reasons: string[] = [];
      if (artist > 1) reasons.push(`Because you listen to ${r.artist_name}`);
      if (genre > 1 && r.top_genre) reasons.push(`Because you like ${r.top_genre}`);
      if (pop > 1) reasons.push('Popular on STREAMERO');
      if (fresh > 0) reasons.push('New release');
      if (!taste.personalized) reasons.splice(0, reasons.length, 'Popular on STREAMERO');
      return { track: presentTrack(r), score, reasons };
    });
    scored.sort((a, b) => b.score - a.score);
    return diversify(scored, opts.limit);
  }

  async mixes(userId: string): Promise<MixDescriptor[]> {
    const taste = await this.taste(userId);
    const genres = [...taste.genres.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3);
    const artistIds = [...taste.artists.entries()].sort((a, b) => b[1] - a[1]).slice(0, 2).map(([id]) => id);
    const artists = artistIds.length
      ? await this.db.query('SELECT id, name FROM artists WHERE id = ANY($1::uuid[])', [artistIds])
      : [];
    const mixes: MixDescriptor[] = [];
    genres.forEach(([g], i) =>
      mixes.push({ id: `genre:${g}`, kind: 'genre', title: `${capitalize(g)} Mix`, description: `Your ${g} favourites and similar tracks`, seed: String(i) }),
    );
    for (const a of artistIds.map((id) => artists.find((x) => x.id === id)).filter(Boolean)) {
      mixes.push({ id: `artist:${a.id}`, kind: 'artist', title: `${a.name} Radio`, description: `${a.name} and artists like them`, seed: a.id });
    }
    if (taste.personalized && taste.genres.size > 0) {
      mixes.push({ id: 'discovery', kind: 'discovery', title: 'Discovery Mix', description: 'Artists you have not heard yet, matched to your taste', seed: 'd' });
    }
    if (mixes.length === 0) {
      // New listener: offer the catalog's biggest genres instead of an empty shelf.
      const top = await this.db.query(
        `SELECT g, count(*) AS c FROM tracks, unnest(genres) g WHERE status = 'ready' GROUP BY g ORDER BY c DESC LIMIT 3`,
      );
      for (const t of top) mixes.push({ id: `genre:${t.g}`, kind: 'genre', title: `${capitalize(t.g)} Mix`, description: `A starting point in ${t.g}`, seed: '0' });
    }
    return mixes;
  }

  async mix(userId: string, mixId: string, limit = 50) {
    const taste = await this.taste(userId);
    let tracks;
    let descriptor: Omit<MixDescriptor, 'seed'>;
    if (mixId.startsWith('genre:')) {
      const genre = mixId.slice(6);
      tracks = await this.scoreTracks(userId, taste, { limit, genre });
      descriptor = { id: mixId, kind: 'genre', title: `${capitalize(genre)} Mix`, description: `Your ${genre} favourites and similar tracks` };
    } else if (mixId.startsWith('mood:')) {
      const mood = mixId.slice(5);
      tracks = await this.scoreTracks(userId, taste, { limit, mood });
      descriptor = { id: mixId, kind: 'mood', title: capitalize(mood), description: `Tracks tagged ${mood}` };
    } else if (mixId.startsWith('artist:')) {
      const artistId = mixId.slice(7);
      const artist = await this.db.one('SELECT id, name, genres FROM artists WHERE id = $1', [artistId]);
      if (!artist) throw notFound('Mix');
      const related = await this.db.query(
        `SELECT DISTINCT t2.artist_id FROM tracks t1 JOIN tracks t2 ON t2.genres && t1.genres AND t2.artist_id <> t1.artist_id
         WHERE t1.artist_id = $1 LIMIT 20`,
        [artistId],
      );
      tracks = await this.scoreTracks(userId, taste, { limit, artistIds: [artistId, ...related.map((r) => r.artist_id)] });
      descriptor = { id: mixId, kind: 'artist', title: `${artist.name} Radio`, description: `${artist.name} and artists like them` };
    } else if (mixId === 'discovery') {
      const known = [...taste.artists.keys()];
      tracks = await this.scoreTracks(userId, taste, { limit, excludeArtists: known.length ? known : undefined, excludeLiked: true });
      descriptor = { id: mixId, kind: 'discovery', title: 'Discovery Mix', description: 'Artists you have not heard yet, matched to your taste' };
    } else {
      throw notFound('Mix');
    }
    return { mix: { ...descriptor, artworkUrls: unique(tracks.map((t) => t.track.artworkUrl).filter(Boolean)).slice(0, 4) }, items: tracks };
  }

  async albumRecommendations(userId: string, limit = 12) {
    const taste = await this.taste(userId);
    const genres = [...taste.genres.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([g]) => g);
    const artists = [...taste.artists.keys()].slice(0, 30);
    const rows = await this.db.query(
      `SELECT ${albumSelect},
         (CASE WHEN al.artist_id = ANY($2::uuid[]) THEN 3 ELSE 0 END
          + (SELECT count(*) FROM unnest(al.genres) g WHERE g = ANY($3::text[])) * 2
          + CASE WHEN al.created_at > now() - interval '30 days' THEN 1 ELSE 0 END) AS score
       FROM ${albumFrom}
       WHERE NOT EXISTS (SELECT 1 FROM saved_albums s WHERE s.user_id = $1 AND s.album_id = al.id)
         AND EXISTS (SELECT 1 FROM tracks t WHERE t.album_id = al.id AND t.status = 'ready')
         AND ($5::boolean OR NOT al.explicit)
       ORDER BY score DESC, al.created_at DESC LIMIT $4`,
      [userId, artists, genres, limit, taste.allowExplicit],
    );
    return rows.map(presentAlbum);
  }

  async trending(userId: string | null, limit = 20) {
    const rows = await this.db.query(
      `WITH week AS (SELECT track_id, count(*) AS plays FROM playback_events WHERE played_at > now() - interval '7 days' AND track_id IS NOT NULL GROUP BY track_id)
       SELECT ${trackSelect('$1')}, coalesce(week.plays, 0) AS week_plays FROM ${trackFrom} LEFT JOIN week ON week.track_id = t.id
       WHERE t.status = 'ready' ORDER BY coalesce(week.plays, 0) DESC, t.play_count DESC, t.created_at DESC LIMIT $2`,
      [userId, limit],
    );
    return rows.map(presentTrack);
  }

  async favoriteArtists(userId: string, limit = 12) {
    const taste = await this.taste(userId);
    const ids = [...taste.artists.entries()].sort((a, b) => b[1] - a[1]).slice(0, limit).map(([id]) => id);
    if (!ids.length) return [];
    const rows = await this.db.query(`SELECT ${artistSelect} FROM artists ar WHERE ar.id = ANY($1::uuid[])`, [ids]);
    return ids.map((id) => rows.find((r) => r.id === id)).filter(Boolean).map(presentArtist);
  }
}

/** Limits each artist to ~2 consecutive slots so mixes do not collapse into one artist. */
export function diversify<T extends { track: { artist: { id: string } } }>(items: T[], limit: number): T[] {
  const out: T[] = [];
  const deferred: T[] = [];
  const perArtist = new Map<string, number>();
  const cap = Math.max(2, Math.ceil(limit / 8));
  for (const item of items) {
    const n = perArtist.get(item.track.artist.id) ?? 0;
    if (n >= cap) deferred.push(item);
    else {
      out.push(item);
      perArtist.set(item.track.artist.id, n + 1);
    }
    if (out.length >= limit) return out;
  }
  return [...out, ...deferred].slice(0, limit);
}

const capitalize = (s: string) => s.charAt(0).toUpperCase() + s.slice(1);
const unique = <T>(xs: T[]) => [...new Set(xs)];
