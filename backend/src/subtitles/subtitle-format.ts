export interface Cue {
  startMs: number;
  endMs: number;
  text: string;
  settings?: string;
}

const TIME = /(?:(\d{1,2}):)?(\d{1,2}):(\d{2})[.,](\d{1,3})/;
const ARROW = /^\s*((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d{1,2}:)?\d{1,2}:\d{2}[.,]\d{1,3})(.*)$/;

export function parseTimestamp(v: string): number {
  const m = v.trim().match(TIME);
  if (!m) throw new Error(`Invalid timestamp: ${v}`);
  const [, h = '0', mm, ss, frac] = m;
  return ((Number(h) * 60 + Number(mm)) * 60 + Number(ss)) * 1000 + Number(frac.padEnd(3, '0'));
}

export function formatVttTimestamp(ms: number): string {
  const v = Math.max(0, Math.round(ms));
  const h = Math.floor(v / 3_600_000);
  const m = Math.floor((v % 3_600_000) / 60_000);
  const s = Math.floor((v % 60_000) / 1000);
  const f = v % 1000;
  return `${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}.${String(f).padStart(3, '0')}`;
}

function normaliseText(input: string): string {
  // Strip a UTF-8 BOM, normalise newlines.
  return input.replace(/^﻿/, '').replace(/\r\n?/g, '\n');
}

/** Parses SRT or WebVTT into cues. Malformed blocks are skipped rather than failing the whole file. */
export function parseSubtitles(input: string): { format: 'srt' | 'vtt'; cues: Cue[] } {
  const text = normaliseText(input);
  const format = /^WEBVTT/.test(text.trimStart()) ? 'vtt' : 'srt';
  const blocks = text.split(/\n{2,}/);
  const cues: Cue[] = [];
  for (const block of blocks) {
    const lines = block.split('\n').filter((l, i, arr) => !(i === arr.length - 1 && l === ''));
    const idx = lines.findIndex((l) => ARROW.test(l));
    if (idx < 0) continue;
    const m = lines[idx].match(ARROW)!;
    try {
      const startMs = parseTimestamp(m[1]);
      const endMs = parseTimestamp(m[2]);
      if (endMs <= startMs) continue;
      const body = lines.slice(idx + 1).join('\n').trim();
      if (!body) continue;
      cues.push({ startMs, endMs, text: format === 'srt' ? srtMarkupToVtt(body) : body, settings: format === 'vtt' ? m[3].trim() || undefined : undefined });
    } catch {
      continue;
    }
  }
  cues.sort((a, b) => a.startMs - b.startMs);
  return { format, cues };
}

/** SRT allows <b>, <i>, <u> and <font>; WebVTT supports b/i/u but not <font>. Escape stray ampersands. */
function srtMarkupToVtt(text: string): string {
  return text
    .replace(/<\/?font[^>]*>/gi, '')
    .replace(/\{\\an?\d+\}/g, '')
    .replace(/&(?![a-z]+;|#\d+;)/gi, '&amp;');
}

export function toWebVtt(cues: Cue[], offsetMs = 0): string {
  const out = ['WEBVTT', ''];
  cues.forEach((c, i) => {
    out.push(String(i + 1));
    out.push(`${formatVttTimestamp(c.startMs + offsetMs)} --> ${formatVttTimestamp(c.endMs + offsetMs)}${c.settings ? ' ' + c.settings : ''}`);
    out.push(c.text, '');
  });
  return out.join('\n');
}

/** Converts uploaded SRT/VTT to normalised WebVTT. Throws when no cue could be parsed. */
export function normaliseToWebVtt(input: string, offsetMs = 0): { vtt: string; cueCount: number; sourceFormat: 'srt' | 'vtt' } {
  const { format, cues } = parseSubtitles(input);
  if (cues.length === 0) throw new Error('No valid subtitle cues found');
  return { vtt: toWebVtt(cues, offsetMs), cueCount: cues.length, sourceFormat: format };
}

/** Adds the HLS X-TIMESTAMP-MAP header so WebVTT cues align with MPEG-TS segment timestamps. */
export function withTimestampMap(vtt: string, mpegtsStart: number): string {
  return vtt.replace(/^WEBVTT[^\n]*\n/, (header) => `${header}X-TIMESTAMP-MAP=MPEGTS:${mpegtsStart},LOCAL:00:00:00.000\n`);
}
