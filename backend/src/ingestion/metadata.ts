import path from 'node:path';
import { type ProbeResult, tag } from '../media/ffmpeg.js';

export interface TrackOverrides {
  title?: string;
  artistName?: string;
  albumTitle?: string;
  albumArtistName?: string;
  albumType?: 'album' | 'single' | 'ep' | 'compilation';
  releaseDate?: string;
  genres?: string[];
  moods?: string[];
  explicit?: boolean;
  trackNumber?: number;
  discNumber?: number;
  downloadable?: boolean;
  isrc?: string;
  lyrics?: string;
  lyricsSource?: string;
  lyricsLicense?: string;
}

export interface TrackMetadata {
  title: string;
  artistName: string;
  albumTitle: string | null;
  albumArtistName: string;
  albumType: 'album' | 'single' | 'ep' | 'compilation';
  releaseDate: string | null;
  genres: string[];
  moods: string[];
  explicit: boolean;
  trackNumber: number | null;
  discNumber: number;
  isrc: string | null;
  label: string | null;
  lyrics: string | null;
}

const clean = (v?: string | null, max = 300) => {
  const s = v?.replace(/[\u0000-\u001f\u007f]/g, ' ').replace(/\s+/g, ' ').trim();
  return s ? s.slice(0, max) : undefined;
};

/** "3/12" -> 3 */
export const leadingInt = (v?: string) => {
  const n = parseInt(v ?? '', 10);
  return Number.isFinite(n) && n > 0 && n < 10_000 ? n : null;
};

export function splitList(v?: string): string[] {
  if (!v) return [];
  return [...new Set(v.split(/[;,/|]/).map((s) => s.trim().toLowerCase()).filter((s) => s.length > 0 && s.length <= 60))].slice(0, 10);
}

/** Accepts "2021", "2021-05", "2021-05-14" or full timestamps; returns an ISO date or null. */
export function normaliseDate(v?: string): string | null {
  if (!v) return null;
  const m = v.trim().match(/^(\d{4})(?:-(\d{2}))?(?:-(\d{2}))?/);
  if (!m) return null;
  const y = Number(m[1]);
  if (y < 1800 || y > 2200) return null;
  return `${m[1]}-${m[2] ?? '01'}-${m[3] ?? '01'}`;
}

/** Derives catalog metadata from container tags, falling back to the file name. Admin overrides win. */
export function extractTrackMetadata(probe: ProbeResult, filename: string, o: TrackOverrides = {}): TrackMetadata {
  const base = path.basename(filename, path.extname(filename));
  // "Artist - Title" file names are common for untagged files.
  const [fnArtist, fnTitle] = base.includes(' - ') ? base.split(' - ', 2) : [undefined, base];
  const artistName = clean(o.artistName) ?? clean(tag(probe, 'artist', 'ARTIST', 'performer')) ?? clean(fnArtist) ?? 'Unknown Artist';
  const albumTitle = clean(o.albumTitle) ?? clean(tag(probe, 'album')) ?? null;
  const advisory = tag(probe, 'ITUNESADVISORY', 'rating', 'explicit');
  const lyrics = o.lyrics ?? tag(probe, 'lyrics', 'LYRICS', 'UNSYNCEDLYRICS', 'lyrics-eng', 'lyrics-XXX', '©lyr') ?? null;
  return {
    title: clean(o.title, 500) ?? clean(tag(probe, 'title'), 500) ?? clean(fnTitle, 500) ?? 'Untitled',
    artistName,
    albumTitle,
    albumArtistName: clean(o.albumArtistName) ?? clean(tag(probe, 'album_artist', 'ALBUMARTIST', 'album artist')) ?? artistName,
    albumType: o.albumType ?? (tag(probe, 'compilation') === '1' ? 'compilation' : albumTitle ? 'album' : 'single'),
    releaseDate: normaliseDate(o.releaseDate) ?? normaliseDate(tag(probe, 'date', 'originaldate', 'year', 'TDRC', 'creation_time')),
    genres: o.genres?.map((g) => g.toLowerCase().trim()).filter(Boolean) ?? splitList(tag(probe, 'genre')),
    moods: o.moods?.map((g) => g.toLowerCase().trim()).filter(Boolean) ?? splitList(tag(probe, 'mood')),
    explicit: o.explicit ?? (advisory === '1' || advisory?.toLowerCase() === 'explicit'),
    trackNumber: o.trackNumber ?? leadingInt(tag(probe, 'track', 'tracknumber')),
    discNumber: o.discNumber ?? leadingInt(tag(probe, 'disc', 'discnumber')) ?? 1,
    isrc: clean(o.isrc, 15) ?? clean(tag(probe, 'isrc', 'TSRC'), 15) ?? null,
    label: clean(tag(probe, 'label', 'publisher', 'organization')) ?? null,
    lyrics: lyrics ? lyrics.slice(0, 100_000) : null,
  };
}

const ISO639: Record<string, string> = {
  eng: 'en', spa: 'es', fre: 'fr', fra: 'fr', ger: 'de', deu: 'de', ita: 'it', por: 'pt', rus: 'ru', jpn: 'ja', kor: 'ko',
  chi: 'zh', zho: 'zh', hrv: 'hr', srp: 'sr', bos: 'bs', slv: 'sl', pol: 'pl', cze: 'cs', ces: 'cs', dut: 'nl', nld: 'nl',
  swe: 'sv', nor: 'no', dan: 'da', fin: 'fi', tur: 'tr', ara: 'ar', heb: 'he', hin: 'hi', hun: 'hu', gre: 'el', ell: 'el',
  ukr: 'uk', rum: 'ro', ron: 'ro', bul: 'bg', mac: 'mk', mkd: 'mk', slo: 'sk', slk: 'sk',
};

/** Maps ISO 639-2 stream language tags to BCP 47 tags that HLS and AVFoundation expect. */
export function toBcp47(lang?: string): string {
  const l = (lang ?? '').toLowerCase().trim();
  if (/^[a-z]{2}(-[a-z0-9]{2,8})*$/i.test(l)) return l;
  return ISO639[l] ?? 'und';
}

export function languageName(code: string): string {
  try {
    return new Intl.DisplayNames(['en'], { type: 'language' }).of(code) ?? code;
  } catch {
    return code;
  }
}

/** Keeps uploaded file names usable in storage keys and logs without allowing path tricks. */
export function safeFileName(name: string): string {
  const base = path.basename(name).normalize('NFKD').replace(/[^\w.\-]+/g, '_').replace(/^\.+/, '');
  return (base || 'upload').slice(-120);
}
