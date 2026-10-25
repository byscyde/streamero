import { describe, expect, it } from 'vitest';
import { LyricsTimeline, parseLRC } from './lyrics';

const timeline = LyricsTimeline.fromResponse({
  trackId: 't',
  synced: true,
  lines: [
    { startMs: 12000, text: 'second' },
    { startMs: 2000, text: 'first', words: [{ startMs: 2000, text: 'fir' }, { startMs: 2500, text: 'st' }] },
    { startMs: 20000, text: 'third' },
  ],
});

describe('LyricsTimeline', () => {
  it('sorts synced lines and finds the active line', () => {
    expect(timeline.lines.map((l) => l.text)).toEqual(['first', 'second', 'third']);
    expect(timeline.activeIndex(0)).toBeNull();
    expect(timeline.activeIndex(2)).toBe(0);
    expect(timeline.activeIndex(11.999)).toBe(0);
    expect(timeline.activeIndex(12)).toBe(1);
    expect(timeline.activeIndex(500)).toBe(2);
  });

  it('computes line progress and sung words', () => {
    expect(timeline.lineProgress(7, 30)).toBeCloseTo(0.5);
    expect(timeline.lineProgress(25, 30)).toBeCloseTo(0.5); // last line ends at track end
    expect(timeline.wordsSung(2.2)).toBe(1);
    expect(timeline.wordsSung(3)).toBe(2);
  });

  it('never highlights unsynced lyrics', () => {
    const t = new LyricsTimeline([{ id: 0, start: -1, text: 'a', words: [] }], false);
    expect(t.activeIndex(10)).toBeNull();
  });
});

describe('parseLRC', () => {
  it('parses timestamps, repeated stamps, offset and word timings', () => {
    const t = parseLRC('[ar:Someone]\n[offset:500]\n[00:01.00][00:10.50]Chorus\n[00:05.00]<00:05.00>Hel <00:05.50>lo\nplain line');
    expect(t.synced).toBe(true);
    expect(t.lines.map((l) => [l.start, l.text])).toEqual([
      [0.5, 'Chorus'],
      [4.5, 'Hel lo'],
      [10, 'Chorus'],
    ]);
    expect(t.lines[1].words).toEqual([
      { start: 4.5, text: 'Hel' },
      { start: 5, text: 'lo' },
    ]);
  });

  it('returns plain lyrics when there are no timestamps', () => {
    const t = parseLRC('one\r\ntwo\n\nthree');
    expect(t.synced).toBe(false);
    expect(t.lines.map((l) => l.text)).toEqual(['one', 'two', 'three']);
  });
});
