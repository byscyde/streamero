/** Time-indexed lyrics (port of StreameroCore/Lyrics.swift). Times are in seconds. */
import type { LyricsResponse } from './types';

export interface LyricLine {
  id: number;
  start: number; // seconds; -1 for unsynchronised lines
  text: string;
  words: { start: number; text: string }[];
}

export class LyricsTimeline {
  readonly lines: LyricLine[];
  constructor(
    lines: LyricLine[],
    readonly synced: boolean,
  ) {
    this.lines = synced ? [...lines].sort((a, b) => a.start - b.start) : lines;
  }

  static fromResponse(r: LyricsResponse): LyricsTimeline {
    return new LyricsTimeline(
      r.lines.map((l, i) => ({ id: i, start: l.startMs / 1000, text: l.text, words: (l.words ?? []).map((w) => ({ start: w.startMs / 1000, text: w.text })) })),
      r.synced,
    );
  }

  /** Index of the line active at `time` (binary search), or null before the first line. */
  activeIndex(time: number): number | null {
    const L = this.lines;
    if (!this.synced || !L.length || time < L[0].start) return null;
    let lo = 0;
    let hi = L.length - 1;
    while (lo < hi) {
      const mid = (lo + hi + 1) >> 1;
      if (L[mid].start <= time) lo = mid;
      else hi = mid - 1;
    }
    return lo;
  }

  /** 0…1 progress through the active line. */
  lineProgress(time: number, duration: number): number {
    const i = this.activeIndex(time);
    if (i === null) return 0;
    const start = this.lines[i].start;
    const end = i + 1 < this.lines.length ? this.lines[i + 1].start : Math.max(start + 1, duration);
    return Math.min(1, Math.max(0, (time - start) / Math.max(0.001, end - start)));
  }

  wordsSung(time: number): number {
    const i = this.activeIndex(time);
    return i === null ? 0 : this.lines[i].words.filter((w) => w.start <= time).length;
  }
}

/** Client-side LRC parser (mirrors the server's and the iOS one). */
export function parseLRC(input: string): LyricsTimeline {
  const lines: LyricLine[] = [];
  let offset = 0;
  let synced = false;
  const stamp = /^\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/;
  const word = /<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/;
  const secs = (m: string, s: string, f?: string) => Number(m) * 60 + Number(s) + (f ? Number(`0.${f}`) : 0);
  for (const raw of input.replace(/\r\n/g, '\n').split('\n')) {
    let line = raw.trim();
    if (!line) continue;
    const meta = /^\[([a-zA-Z]+):(.*)\]$/.exec(line);
    if (meta) {
      if (meta[1].toLowerCase() === 'offset') offset = (Number(meta[2].trim()) || 0) / 1000;
      continue;
    }
    const starts: number[] = [];
    let m: RegExpExecArray | null;
    while ((m = stamp.exec(line))) {
      starts.push(secs(m[1], m[2], m[3]));
      line = line.slice(m[0].length);
    }
    if (!starts.length) {
      lines.push({ id: lines.length, start: -1, text: line, words: [] });
      continue;
    }
    synced = true;
    const words: LyricLine['words'] = [];
    let text = '';
    let rest = line;
    let pending: number | null = null;
    while ((m = word.exec(rest))) {
      const before = rest.slice(0, m.index).trim();
      if (pending !== null && before) words.push({ start: Math.max(0, pending - offset), text: before });
      if (before) text += (text ? ' ' : '') + before;
      pending = secs(m[1], m[2], m[3]);
      rest = rest.slice(m.index + m[0].length);
    }
    const tail = rest.trim();
    if (pending !== null && tail) words.push({ start: Math.max(0, pending - offset), text: tail });
    if (tail) text += (text ? ' ' : '') + tail;
    for (const s of starts) lines.push({ id: lines.length, start: Math.max(0, s - offset), text, words });
  }
  if (!synced) return new LyricsTimeline(lines, false);
  const timed = lines
    .filter((l) => l.start >= 0)
    .sort((a, b) => a.start - b.start)
    .map((l, i) => ({ ...l, id: i }));
  return new LyricsTimeline(timed, true);
}
