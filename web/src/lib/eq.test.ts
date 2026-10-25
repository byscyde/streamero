import { describe, expect, it } from 'vitest';
import {
  applyPreset, bandConfigs, clampDb, dbToGain, DEFAULT_EQ, effectiveGains, EQ_FREQUENCIES, EQ_PRESETS, loadEq, matchPreset, normalizeEq,
  preampGain, saveEq, setBand,
} from './eq';

describe('equalizer bands', () => {
  it('has the 10 ISO-style bands with shelf filters at the ends', () => {
    expect(EQ_FREQUENCIES).toEqual([31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]);
    const b = bandConfigs();
    expect(b).toHaveLength(10);
    expect(b[0].type).toBe('lowshelf');
    expect(b[9].type).toBe('highshelf');
    expect(b.slice(1, 9).every((x) => x.type === 'peaking')).toBe(true);
  });

  it('ships all presets with 10 gains inside ±12 dB', () => {
    expect(Object.keys(EQ_PRESETS)).toEqual(['Flat', 'Bass Boost', 'Treble Boost', 'Vocal', 'Rock', 'Pop', 'Electronic', 'Acoustic', 'Loudness']);
    for (const g of Object.values(EQ_PRESETS)) {
      expect(g).toHaveLength(10);
      expect(g.every((v) => v >= -12 && v <= 12)).toBe(true);
    }
    expect(EQ_PRESETS['Bass Boost'][0]).toBeGreaterThan(EQ_PRESETS['Bass Boost'][9]);
    expect(EQ_PRESETS['Treble Boost'][9]).toBeGreaterThan(EQ_PRESETS['Treble Boost'][0]);
  });
});

describe('equalizer math', () => {
  it('clamps gains and marks hand edits as Custom', () => {
    expect(clampDb(20)).toBe(12);
    expect(clampDb(-30)).toBe(-12);
    expect(clampDb(NaN)).toBe(0);
    const s = setBand(applyPreset(DEFAULT_EQ, 'Rock'), 3, 99);
    expect(s.gains[3]).toBe(12);
    expect(s.preset).toBe('Custom');
    expect(setBand(s, 3, EQ_PRESETS.Rock[3]).preset).toBe('Rock');
  });

  it('recognises presets', () => {
    expect(matchPreset([...EQ_PRESETS.Pop])).toBe('Pop');
    expect(matchPreset([1, 2, 3, 4, 5, 6, 7, 8, 9, 10])).toBeNull();
  });

  it('bypasses the filters when disabled', () => {
    const s = { ...applyPreset(DEFAULT_EQ, 'Loudness'), enabled: false };
    expect(effectiveGains(s)).toEqual(Array(10).fill(0));
    expect(preampGain(s)).toBe(1);
    expect(effectiveGains({ ...s, enabled: true })).toEqual(EQ_PRESETS.Loudness);
  });

  it('adds headroom for boosts so presets do not clip', () => {
    const s = { ...applyPreset(DEFAULT_EQ, 'Bass Boost'), enabled: true };
    expect(preampGain(s)).toBeCloseTo(dbToGain(-3.5), 6); // half the 7 dB peak
    expect(preampGain({ ...s, preamp: 3.5 })).toBeCloseTo(1, 6);
    expect(dbToGain(6)).toBeCloseTo(1.995, 3);
  });

  it('round-trips through storage and repairs bad data', () => {
    const store = new Map<string, string>();
    const st = { getItem: (k: string) => store.get(k) ?? null, setItem: (k: string, v: string) => void store.set(k, v) };
    const s = { ...applyPreset(DEFAULT_EQ, 'Vocal'), enabled: true, preamp: -2 };
    saveEq(s, st);
    expect(loadEq(st)).toEqual(s);
    expect(normalizeEq({ gains: [1, 2], enabled: 'yes', preamp: 99 })).toEqual({ enabled: false, preset: 'Flat', gains: Array(10).fill(0), preamp: 12 });
    expect(loadEq({ getItem: () => '{broken' })).toEqual(DEFAULT_EQ);
  });
});
