export interface LyricWord {
  startMs: number;
  text: string;
}

export interface LyricLine {
  startMs: number;
  text: string;
  words?: LyricWord[];
}

export interface ParsedLyrics {
  synced: boolean;
  lines: LyricLine[];
  metadata: Record<string, string>;
  offsetMs: number;
}

const LINE_TAG = /\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]/g;
const WORD_TAG = /<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>/g;
const META_TAG = /^\[([a-z]+):(.*)\]$/i;

const toMs = (m: string, s: string, f?: string) => (Number(m) * 60 + Number(s)) * 1000 + (f ? Number(f.padEnd(3, '0').slice(0, 3)) : 0);

/**
 * Parses LRC (including the "enhanced" <mm:ss.xx> word-timing extension). A line may carry several
 * timestamps (repeated choruses). Text without timestamps is treated as plain, unsynchronised lyrics.
 */
export function parseLrc(input: string): ParsedLyrics {
  const metadata: Record<string, string> = {};
  const lines: LyricLine[] = [];
  const raw = input.replace(/^﻿/, '').replace(/\r\n?/g, '\n').split('\n');
  let sawTimestamp = false;
  for (const rawLine of raw) {
    const line = rawLine.trim();
    if (!line) continue;
    const meta = line.match(META_TAG);
    if (meta && !/^\d/.test(meta[1])) {
      metadata[meta[1].toLowerCase()] = meta[2].trim();
      continue;
    }
    const stamps: number[] = [];
    LINE_TAG.lastIndex = 0;
    let m: RegExpExecArray | null;
    let lastEnd = 0;
    while ((m = LINE_TAG.exec(line)) && m.index === lastEnd) {
      stamps.push(toMs(m[1], m[2], m[3]));
      lastEnd = LINE_TAG.lastIndex;
    }
    const body = line.slice(lastEnd);
    if (stamps.length === 0) {
      lines.push({ startMs: -1, text: line });
      continue;
    }
    sawTimestamp = true;
    const words: LyricWord[] = [];
    WORD_TAG.lastIndex = 0;
    const parts = body.split(WORD_TAG);
    // split() with 3 capture groups yields [text, m, s, f, text, m, s, f, text...]
    if (parts.length > 1) {
      for (let i = 1; i + 3 < parts.length + 1; i += 4) {
        const text = (parts[i + 3] ?? '').trim();
        if (text) words.push({ startMs: toMs(parts[i], parts[i + 1], parts[i + 2]), text });
      }
    }
    const text = body.replace(WORD_TAG, '').replace(/\s+/g, ' ').trim();
    for (const startMs of stamps) lines.push({ startMs, text, ...(words.length ? { words } : {}) });
  }
  const offsetMs = Number(metadata.offset ?? 0) || 0;
  if (!sawTimestamp) return { synced: false, lines: lines.map((l) => ({ startMs: -1, text: l.text })), metadata, offsetMs: 0 };
  const synced = lines
    .filter((l) => l.startMs >= 0)
    .map((l) => ({
      ...l,
      // LRC offset: positive values make lyrics appear sooner.
      startMs: Math.max(0, l.startMs - offsetMs),
      words: l.words?.map((w) => ({ ...w, startMs: Math.max(0, w.startMs - offsetMs) })),
    }))
    .sort((a, b) => a.startMs - b.startMs);
  return { synced: true, lines: synced, metadata, offsetMs };
}
