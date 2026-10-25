import { Injectable, Logger } from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { badRequest, notFound } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { normaliseDate } from '../ingestion/metadata.js';
import { MediaProcessor } from '../ingestion/processor.js';
import { AssetsService } from '../media/assets.service.js';
import { joinCredit, MusicBrainzClient, pickRelease, topGenres, type MbRelease, type MetadataSearchResult } from './musicbrainz.js';

/** Minimum confidence (0..100) for unattended matches (METADATA_AUTOFILL). */
export const AUTOFILL_CONFIDENCE = 90;

export interface ApplyInput {
  trackId: string;
  recordingId: string;
  releaseId?: string;
  overwrite?: boolean;
}

export interface ApplyOutcome {
  fields: string[];
  cover: 'stored' | 'kept' | 'not_available' | 'failed' | 'skipped';
}

const norm = (s?: string | null) =>
  (s ?? '')
    .normalize('NFKD')
    .replace(/[̀-ͯ]/g, '')
    .toLowerCase()
    .replace(/\(.*?\)|\[.*?\]/g, ' ')
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();

/** Dice coefficient on character bigrams: 1 = identical, 0 = nothing in common. */
export function similarity(a: string, b: string): number {
  const x = norm(a);
  const y = norm(b);
  if (!x || !y) return 0;
  if (x === y) return 1;
  const grams = (s: string) => {
    const m = new Map<string, number>();
    for (let i = 0; i < s.length - 1; i++) m.set(s.slice(i, i + 2), (m.get(s.slice(i, i + 2)) ?? 0) + 1);
    return m;
  };
  const gx = grams(x);
  const gy = grams(y);
  let inter = 0;
  for (const [g, n] of gx) inter += Math.min(n, gy.get(g) ?? 0);
  return (2 * inter) / (Math.max(1, x.length - 1) + Math.max(1, y.length - 1));
}

const isUnknownArtist = (name?: string | null) => !name || norm(name) === 'unknown artist';
const isPlaceholderTitle = (title?: string | null) => !title || norm(title) === 'untitled';

function albumTypeOf(release: MbRelease): 'album' | 'single' | 'ep' | 'compilation' {
  const rg = release['release-group'];
  if (rg?.['secondary-types']?.includes('Compilation')) return 'compilation';
  if (rg?.['primary-type'] === 'Single') return 'single';
  if (rg?.['primary-type'] === 'EP') return 'ep';
  return 'album';
}

function findTrackPosition(release: MbRelease, recordingId: string) {
  for (const medium of release.media ?? []) {
    for (const t of medium.tracks ?? medium.track ?? []) {
      if (t.recording?.id === recordingId) {
        const n = t.position ?? parseInt(t.number ?? '', 10);
        return { trackNumber: Number.isFinite(n) && n > 0 ? n : null, discNumber: medium.position && medium.position > 0 ? medium.position : 1 };
      }
    }
  }
  return null;
}

/**
 * Fills catalog metadata for files you own from MusicBrainz + Cover Art Archive (docs/APP_CONFIG.md §3).
 * Metadata and cover images only: STREAMERO never downloads audio from streaming sites.
 */
@Injectable()
export class MetadataService {
  private readonly logger = new Logger(MetadataService.name);

  constructor(
    private readonly db: DbService,
    private readonly mb: MusicBrainzClient,
    private readonly processor: MediaProcessor,
    private readonly assets: AssetsService,
    private readonly audit: AuditService,
  ) {}

  search(q: string): Promise<MetadataSearchResult[]> {
    const query = q.trim().slice(0, 200);
    if (query.length < 2) throw badRequest('invalid_query', 'Enter at least 2 characters (artist and/or title)');
    return this.mb.searchRecordings(query, 25);
  }

  /**
   * Applies a MusicBrainz recording (and release) to a track. Without `overwrite` only empty or placeholder
   * values are filled (Untitled, Unknown Artist, no/auto-created single album, no genres, no track number,
   * no release date, no artwork); with `overwrite` MusicBrainz values replace the existing ones.
   */
  async apply(actorId: string | null, input: ApplyInput): Promise<ApplyOutcome> {
    const track = await this.loadTrack(input.trackId);
    if (!track) throw notFound('Track');
    const recording = await this.mb.getRecording(input.recordingId);
    const releaseRef = input.releaseId ? { id: input.releaseId } : pickRelease(recording.releases);
    const release = releaseRef ? await this.mb.getRelease(releaseRef.id) : null;
    const overwrite = !!input.overwrite;

    const title = recording.title?.trim().slice(0, 500);
    const artistName = joinCredit(recording['artist-credit']).slice(0, 300);
    const genres = topGenres(recording.genres, release?.genres, release?.['release-group']?.genres, recording.genres?.length ? undefined : recording.tags);
    const position = release ? findTrackPosition(release, recording.id) : null;
    const isrc = recording.isrcs?.[0]?.slice(0, 15) ?? null;
    const autoSingle = !track.album_id || (track.album_type === 'single' && norm(track.album_title) === norm(track.title));

    const fields: string[] = [];
    let targetAlbumId: string | null = track.album_id;
    await this.db.tx(async (client) => {
      const set: Record<string, unknown> = {};
      if (title && (overwrite || isPlaceholderTitle(track.title)) && title !== track.title) set.title = title;
      if (artistName && (overwrite || isUnknownArtist(track.artist_name)) && artistName !== track.artist_name) {
        set.artist_id = (await this.db.one(
          `INSERT INTO artists (name) VALUES ($1) ON CONFLICT ((lower(name))) DO UPDATE SET name = artists.name RETURNING id`,
          [artistName],
          client,
        )).id;
        fields.push('artist');
      }
      if (release && (overwrite || autoSingle)) {
        const albumArtist = joinCredit(release['artist-credit']).slice(0, 300) || artistName || track.artist_name;
        const albumArtistId = (await this.db.one(
          `INSERT INTO artists (name) VALUES ($1) ON CONFLICT ((lower(name))) DO UPDATE SET name = artists.name RETURNING id`,
          [albumArtist],
          client,
        )).id;
        const album = await this.db.one(
          `INSERT INTO albums (title, artist_id, album_type, release_date, genres, label) VALUES ($1, $2, $3, $4, $5, $6)
           ON CONFLICT (artist_id, (lower(title))) DO UPDATE SET title = albums.title RETURNING id`,
          [release.title.slice(0, 300), albumArtistId, albumTypeOf(release), normaliseDate(release.date), genres, release['label-info']?.[0]?.label?.name?.slice(0, 200) ?? null],
          client,
        );
        if (album.id !== track.album_id) {
          set.album_id = album.id;
          targetAlbumId = album.id;
        }
      }
      if (position?.trackNumber && (overwrite || !track.track_number) && position.trackNumber !== track.track_number) {
        set.track_number = position.trackNumber;
        set.disc_number = position.discNumber;
      }
      if (genres.length && (overwrite || track.genres.length === 0)) set.genres = genres;
      if (isrc && !track.isrc) set.isrc = isrc;

      const keys = Object.keys(set);
      if (keys.length) {
        await this.db.query(
          `UPDATE tracks SET ${keys.map((k, i) => `${k} = $${i + 2}`).join(', ')} WHERE id = $1`,
          [track.id, ...keys.map((k) => set[k])],
          client,
        );
        fields.push(...keys.filter((k) => k !== 'artist_id').map((k) => ({ album_id: 'album', track_number: 'trackNumber', disc_number: 'discNumber' })[k] ?? k));
      }
      // Year/genres/label live on the album: fill them on whichever album the track now belongs to.
      if (release && targetAlbumId) {
        const date = normaliseDate(release.date ?? recording['first-release-date']);
        const before = await this.db.one('SELECT release_date::text AS d FROM albums WHERE id = $1 FOR UPDATE', [targetAlbumId], client);
        const after = await this.db.one(
          `UPDATE albums SET
             release_date = CASE WHEN $2::date IS NOT NULL AND ($5 OR release_date IS NULL) THEN $2::date ELSE release_date END,
             genres = CASE WHEN cardinality($3::text[]) > 0 AND ($5 OR genres = '{}') THEN $3::text[] ELSE genres END,
             label = CASE WHEN $4::text IS NOT NULL AND ($5 OR label IS NULL) THEN $4 ELSE label END
           WHERE id = $1 RETURNING release_date::text AS d`,
          [targetAlbumId, date, genres, release['label-info']?.[0]?.label?.name?.slice(0, 200) ?? null, overwrite],
          client,
        );
        if (after?.d && (after.d !== before?.d || set.album_id)) fields.push('year');
      }
    });

    // The auto-created single the track came from is removed once nothing is left in it.
    if (track.album_id && targetAlbumId !== track.album_id) {
      const left = await this.db.one('SELECT count(*)::int AS n FROM tracks WHERE album_id = $1', [track.album_id]);
      if (left.n === 0) {
        const old = await this.db.one('DELETE FROM albums WHERE id = $1 RETURNING artwork_asset_id', [track.album_id]);
        await this.assets.deleteIfUnreferenced([old?.artwork_asset_id]);
      }
    }

    let cover: ApplyOutcome['cover'] = 'skipped';
    if (release && targetAlbumId) {
      const album = await this.db.one('SELECT artwork_asset_id FROM albums WHERE id = $1', [targetAlbumId]);
      if (album?.artwork_asset_id && !overwrite) cover = 'kept';
      else {
        const bytes = await this.mb.fetchCover(release.id);
        if (!bytes) cover = 'not_available';
        else {
          try {
            await this.processor.storeArtworkBuffer(bytes, 'album', targetAlbumId);
            cover = 'stored';
            fields.push('artwork');
          } catch (err) {
            this.logger.warn({ err: (err as Error).message, releaseId: release.id }, 'Could not store cover art');
            cover = 'failed';
          }
        }
      }
    }

    await this.audit.record({
      actorId,
      action: actorId ? 'metadata.apply' : 'metadata.autofill',
      targetType: 'track',
      targetId: track.id,
      metadata: { recordingId: recording.id, releaseId: release?.id ?? null, overwrite, fields, cover },
    });
    return { fields, cover };
  }

  private loadTrack(id: string) {
    return this.db.one(
      `SELECT t.id, t.title, t.album_id, t.track_number, t.genres, t.isrc, t.duration_ms, ar.name AS artist_name,
         al.title AS album_title, al.album_type, al.artwork_asset_id
       FROM tracks t JOIN artists ar ON ar.id = t.artist_id LEFT JOIN albums al ON al.id = t.album_id WHERE t.id = $1`,
      [id],
    );
  }

  /**
   * Worker auto-fill (METADATA_AUTOFILL=true): for a freshly ingested track whose tags lack artist, album,
   * genre or artwork, searches MusicBrainz and applies the best match only when confidence >= 90 %.
   * Confidence combines the MusicBrainz score with title/artist similarity and duration agreement.
   */
  async autofill(trackId: string, log: (m: string) => Promise<void> = async () => {}): Promise<ApplyOutcome | null> {
    const t = await this.loadTrack(trackId);
    if (!t) return null;
    const autoSingle = !t.album_id || (t.album_type === 'single' && norm(t.album_title) === norm(t.title));
    const missing = isUnknownArtist(t.artist_name) || autoSingle || t.genres.length === 0 || !t.artwork_asset_id;
    if (!missing || isPlaceholderTitle(t.title)) return null;
    const artistKnown = !isUnknownArtist(t.artist_name);
    const results = await this.mb.searchRecordings(artistKnown ? `${t.artist_name} - ${t.title}` : t.title, 10);
    const scored = results.map((r) => ({ r, confidence: this.confidence(t, r, artistKnown) })).sort((a, b) => b.confidence - a.confidence);
    const best = scored[0];
    if (!best || best.confidence < AUTOFILL_CONFIDENCE) {
      await log(`Metadata auto-fill: no confident MusicBrainz match${best ? ` (best ${best.confidence}%)` : ''}`);
      return null;
    }
    const outcome = await this.apply(null, { trackId, recordingId: best.r.id, releaseId: best.r.albumId ?? undefined, overwrite: false });
    await log(`Metadata auto-fill: matched "${best.r.artist} – ${best.r.title}" (${best.confidence}%), filled ${outcome.fields.join(', ') || 'nothing'}; cover ${outcome.cover}`);
    return outcome;
  }

  confidence(t: { title: string; artist_name: string; duration_ms: number }, r: MetadataSearchResult, artistKnown: boolean): number {
    const titleSim = similarity(t.title, r.title);
    const artistSim = artistKnown ? similarity(t.artist_name, r.artist) : 0.85; // unknown artist caps confidence
    let durationFactor = 1;
    if (t.duration_ms > 0 && r.durationMs) {
      const diff = Math.abs(t.duration_ms - r.durationMs);
      durationFactor = diff <= 3000 ? 1 : diff <= 10_000 ? 0.9 : 0.6;
    }
    return Math.round(Math.min(1, (r.score ?? 0) / 100) * titleSim * artistSim * durationFactor * 100);
  }
}
