import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { AppError, notFound } from '../common/errors.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { normaliseDate } from '../ingestion/metadata.js';

/**
 * Minimal MusicBrainz + Cover Art Archive client (official, free APIs; metadata only — no audio is ever
 * downloaded from anywhere). MusicBrainz asks for a meaningful User-Agent and at most 1 request/second.
 */
export const USER_AGENT = 'STREAMERO/1.0 ( https://scyde.dev )';
const TIMEOUT_MS = 10_000;
const COVER_TIMEOUT_MS = 15_000;
const MAX_COVER_BYTES = 10 * 1024 * 1024;

export const metadataUnavailable = (message = 'MusicBrainz is unreachable right now, please try again later') =>
  new AppError(HttpStatus.SERVICE_UNAVAILABLE, 'metadata_unavailable', message);

export interface MbArtistCredit {
  name: string;
  joinphrase?: string;
  artist?: { id: string; name: string };
}
export interface MbTag {
  name: string;
  count?: number;
}
export interface MbReleaseGroup {
  id: string;
  'primary-type'?: string | null;
  'secondary-types'?: string[];
  genres?: MbTag[];
}
export interface MbRelease {
  id: string;
  title: string;
  status?: string | null;
  date?: string;
  'artist-credit'?: MbArtistCredit[];
  'release-group'?: MbReleaseGroup;
  'label-info'?: { label?: { name?: string } | null }[];
  genres?: MbTag[];
  media?: { position?: number; track?: MbTrack[]; tracks?: MbTrack[] }[];
}
export interface MbTrack {
  position?: number;
  number?: string;
  title?: string;
  recording?: { id: string };
}
export interface MbRecording {
  id: string;
  score?: number;
  title: string;
  length?: number | null;
  'artist-credit'?: MbArtistCredit[];
  'first-release-date'?: string;
  releases?: MbRelease[];
  genres?: MbTag[];
  tags?: MbTag[];
  isrcs?: string[];
}

/** One search hit, shaped per docs/APP_CONFIG.md §3. */
export interface MetadataSearchResult {
  id: string;
  title: string;
  artist: string;
  album: string | null;
  albumId: string | null;
  year: number | null;
  durationMs: number | null;
  genres: string[];
  coverUrl: string | null;
  /** MusicBrainz relevance score 0..100. */
  score: number;
}

export const joinCredit = (credits?: MbArtistCredit[]) =>
  (credits ?? []).map((c) => `${c.name}${c.joinphrase ?? ''}`).join('').trim();

/** Prefers official studio albums, then singles/EPs, then anything; earliest release first. */
export function pickRelease(releases?: MbRelease[]): MbRelease | null {
  if (!releases?.length) return null;
  const rank = (r: MbRelease) => {
    const rg = r['release-group'];
    let s = 0;
    if (r.status && r.status !== 'Official') s += 100;
    if (rg?.['secondary-types']?.length) s += 20;
    if (rg?.['primary-type'] === 'Album') s += 0;
    else if (rg?.['primary-type'] === 'Single' || rg?.['primary-type'] === 'EP') s += 5;
    else s += 10;
    return s;
  };
  return [...releases].sort((a, b) => rank(a) - rank(b) || (a.date || '9999').localeCompare(b.date || '9999'))[0];
}

export function yearOf(date?: string | null): number | null {
  const d = normaliseDate(date ?? undefined);
  return d ? Number(d.slice(0, 4)) : null;
}

/** Genre names sorted by vote count, lower-cased, de-duplicated, at most 5. */
export function topGenres(...lists: (MbTag[] | undefined)[]): string[] {
  const votes = new Map<string, number>();
  for (const list of lists) for (const t of list ?? []) {
    const name = t.name?.trim().toLowerCase();
    if (!name || name.length > 60) continue;
    votes.set(name, (votes.get(name) ?? 0) + (t.count ?? 1));
  }
  return [...votes.entries()].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([n]) => n);
}

/** Escapes Lucene syntax so user input is always treated as plain words. */
export const luceneEscape = (s: string) => s.replace(/[+\-&|!(){}[\]^"~*?:\\/]/g, ' ').replace(/\s+/g, ' ').trim();

/**
 * Builds a recording query from free text: "Artist - Title" is split into fields; otherwise every word must
 * match the recording title or the artist name (much better than MusicBrainz's title-only default field).
 */
export function buildRecordingQuery(q: string): string {
  const dash = q.split(/\s+[-–—]\s+/);
  if (dash.length === 2 && luceneEscape(dash[0]) && luceneEscape(dash[1])) {
    return `artist:"${luceneEscape(dash[0])}" AND recording:"${luceneEscape(dash[1])}"`;
  }
  const words = luceneEscape(q).split(' ').filter(Boolean).slice(0, 12);
  return words.map((w) => `(recording:${w} OR artist:${w})`).join(' AND ');
}

@Injectable()
export class MusicBrainzClient {
  private readonly logger = new Logger(MusicBrainzClient.name);
  private queue: Promise<unknown> = Promise.resolve();
  private lastRequestAt = 0;
  /** Politeness interval between MusicBrainz requests (tests run without delay). */
  readonly minIntervalMs: number;

  constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {
    this.minIntervalMs = config.NODE_ENV === 'test' ? 0 : 1000;
  }

  /** Serialises requests through one in-process queue so this process never exceeds 1 req/s. */
  private throttled<T>(fn: () => Promise<T>): Promise<T> {
    const run = this.queue.then(async () => {
      const wait = this.lastRequestAt + this.minIntervalMs - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      this.lastRequestAt = Date.now();
      return fn();
    });
    this.queue = run.catch(() => undefined);
    return run;
  }

  private async getJson<T>(path: string, params: Record<string, string>, retry = true): Promise<T> {
    const url = new URL(`${this.config.MUSICBRAINZ_BASE_URL.replace(/\/$/, '')}/${path}`);
    for (const [k, v] of Object.entries({ ...params, fmt: 'json' })) url.searchParams.set(k, v);
    let res: Response;
    try {
      res = await this.throttled(() =>
        globalThis.fetch(url, { headers: { 'User-Agent': USER_AGENT, Accept: 'application/json' }, signal: AbortSignal.timeout(TIMEOUT_MS) }),
      );
    } catch (err) {
      this.logger.warn({ err: (err as Error).message, path }, 'MusicBrainz request failed');
      throw metadataUnavailable();
    }
    if (res.status === 404) throw notFound('MusicBrainz entry');
    // 503 is MusicBrainz's rate-limit / overload answer: retry once after a pause, then give up gracefully.
    if (res.status === 503 && retry) {
      await new Promise((r) => setTimeout(r, Math.max(this.minIntervalMs, 1) * 1.5));
      return this.getJson<T>(path, params, false);
    }
    if (res.status === 400) throw new AppError(HttpStatus.BAD_REQUEST, 'invalid_query', 'MusicBrainz rejected the query');
    if (!res.ok) {
      this.logger.warn({ status: res.status, path }, 'MusicBrainz returned an error');
      throw metadataUnavailable();
    }
    try {
      return (await res.json()) as T;
    } catch {
      throw metadataUnavailable('MusicBrainz returned an invalid response');
    }
  }

  coverUrl(releaseId: string, size: 250 | 500 = 250) {
    return `${this.config.COVERART_BASE_URL.replace(/\/$/, '')}/release/${releaseId}/front-${size}`;
  }

  async searchRecordings(q: string, limit = 25): Promise<MetadataSearchResult[]> {
    const query = buildRecordingQuery(q);
    if (!query) return [];
    const data = await this.getJson<{ recordings?: MbRecording[] }>('recording', { query, limit: String(Math.min(25, limit)) });
    return (data.recordings ?? []).map((r) => {
      const rel = pickRelease(r.releases);
      return {
        id: r.id,
        title: r.title,
        artist: joinCredit(r['artist-credit']),
        album: rel?.title ?? null,
        albumId: rel?.id ?? null,
        year: yearOf(r['first-release-date'] ?? rel?.date),
        durationMs: r.length ?? null,
        genres: topGenres(r.genres?.length ? r.genres : r.tags),
        coverUrl: rel ? this.coverUrl(rel.id) : null,
        score: r.score ?? 0,
      };
    });
  }

  getRecording(id: string) {
    return this.getJson<MbRecording>(`recording/${encodeURIComponent(id)}`, { inc: 'artist-credits+releases+release-groups+genres+tags+isrcs' });
  }

  getRelease(id: string) {
    return this.getJson<MbRelease>(`release/${encodeURIComponent(id)}`, { inc: 'recordings+artist-credits+release-groups+genres+labels' });
  }

  /** Front cover (500 px) from the Cover Art Archive, or null when the release has none. Never throws. */
  async fetchCover(releaseId: string): Promise<Buffer | null> {
    try {
      const res = await globalThis.fetch(this.coverUrl(releaseId, 500), {
        headers: { 'User-Agent': USER_AGENT },
        redirect: 'follow',
        signal: AbortSignal.timeout(COVER_TIMEOUT_MS),
      });
      if (!res.ok) return null;
      const declared = Number(res.headers.get('content-length') ?? 0);
      if (declared > MAX_COVER_BYTES) return null;
      const buf = Buffer.from(await res.arrayBuffer());
      return buf.length > 0 && buf.length <= MAX_COVER_BYTES ? buf : null;
    } catch (err) {
      this.logger.warn({ err: (err as Error).message, releaseId }, 'Cover Art Archive request failed');
      return null;
    }
  }
}
