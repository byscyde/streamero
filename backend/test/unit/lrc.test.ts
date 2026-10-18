import { describe, expect, it } from 'vitest';
import { parseLrc } from '../../src/lyrics/lrc.js';

describe('LRC parser', () => {
  it('parses synced lyrics with metadata, repeated timestamps and offset', () => {
    const lrc = `[ar:Artist]\n[ti:Song]\n[offset:500]\n[00:12.00]First line\n[00:20.50][01:10.25]Chorus\n\n[00:15.3]Middle`;
    const r = parseLrc(lrc);
    expect(r.synced).toBe(true);
    expect(r.metadata).toMatchObject({ ar: 'Artist', ti: 'Song' });
    expect(r.offsetMs).toBe(500);
    expect(r.lines.map((l) => [l.startMs, l.text])).toEqual([
      [11500, 'First line'],
      [14800, 'Middle'],
      [20000, 'Chorus'],
      [69750, 'Chorus'],
    ]);
  });

  it('parses enhanced word timestamps', () => {
    const r = parseLrc('[00:01.00]<00:01.00>Hello <00:01.50>big <00:02.00>world');
    expect(r.lines[0].text).toBe('Hello big world');
    expect(r.lines[0].words).toEqual([
      { startMs: 1000, text: 'Hello' },
      { startMs: 1500, text: 'big' },
      { startMs: 2000, text: 'world' },
    ]);
  });

  it('treats text without timestamps as plain lyrics', () => {
    const r = parseLrc('Line one\nLine two');
    expect(r.synced).toBe(false);
    expect(r.lines).toEqual([
      { startMs: -1, text: 'Line one' },
      { startMs: -1, text: 'Line two' },
    ]);
  });
});
