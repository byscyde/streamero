/** 10-band graphic equalizer: band layout, presets and persisted settings (pure logic, unit-tested). */

export const EQ_FREQUENCIES = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000] as const;
export const EQ_MIN_DB = -12;
export const EQ_MAX_DB = 12;
export const EQ_Q = 1.41; // ~1 octave bandwidth for the peaking bands

export interface BandConfig {
  frequency: number;
  type: BiquadFilterType;
  Q: number;
}

/** Lowest band is a low shelf, highest a high shelf, everything in between peaking filters. */
export function bandConfigs(): BandConfig[] {
  return EQ_FREQUENCIES.map((frequency, i) => ({
    frequency,
    type: i === 0 ? 'lowshelf' : i === EQ_FREQUENCIES.length - 1 ? 'highshelf' : 'peaking',
    Q: i === 0 || i === EQ_FREQUENCIES.length - 1 ? 0.7 : EQ_Q,
  }));
}

export const EQ_PRESETS: Record<string, number[]> = {
  Flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'Bass Boost': [7, 6, 5, 3, 1, 0, 0, 0, 0, 0],
  'Treble Boost': [0, 0, 0, 0, 0, 1, 3, 5, 6, 7],
  Vocal: [-3, -2, -1, 1, 4, 5, 4, 2, 0, -1],
  Rock: [5, 4, 2, -1, -2, -1, 2, 4, 5, 5],
  Pop: [-1, 1, 3, 4, 3, 0, -1, -1, 1, 2],
  Electronic: [6, 5, 2, 0, -2, 1, 0, 2, 5, 6],
  Acoustic: [4, 3, 2, 1, 2, 2, 3, 3, 2, 1],
  Loudness: [6, 4, 1, 0, -1, 0, 0, 1, 4, 6],
};

export const EQ_PRESET_NAMES = Object.keys(EQ_PRESETS);

export interface EqSettings {
  enabled: boolean;
  preset: string; // a preset name, or "Custom"
  gains: number[]; // dB per band
  preamp: number; // dB
}

export const DEFAULT_EQ: EqSettings = { enabled: false, preset: 'Flat', gains: [...EQ_PRESETS.Flat], preamp: 0 };

export const clampDb = (v: number) => Math.max(EQ_MIN_DB, Math.min(EQ_MAX_DB, Number.isFinite(v) ? v : 0));

export function applyPreset(s: EqSettings, name: string): EqSettings {
  const gains = EQ_PRESETS[name];
  if (!gains) return s;
  return { ...s, preset: name, gains: [...gains] };
}

export function setBand(s: EqSettings, index: number, db: number): EqSettings {
  if (index < 0 || index >= EQ_FREQUENCIES.length) return s;
  const gains = s.gains.slice();
  gains[index] = Math.round(clampDb(db) * 10) / 10;
  return { ...s, gains, preset: matchPreset(gains) ?? 'Custom' };
}

export function matchPreset(gains: number[]): string | null {
  return EQ_PRESET_NAMES.find((n) => EQ_PRESETS[n].every((g, i) => Math.abs(g - (gains[i] ?? 0)) < 0.05)) ?? null;
}

export const dbToGain = (db: number) => Math.pow(10, db / 20);

/**
 * Effective linear gain for the preamp node. When the EQ boosts, the maximum boost is subtracted
 * automatically (headroom) so loud presets don't clip; the user's preamp is added on top.
 */
export function preampGain(s: EqSettings): number {
  if (!s.enabled) return 1;
  const maxBoost = Math.max(0, ...s.gains);
  return dbToGain(clampDb(s.preamp) - maxBoost * 0.5);
}

/** Gains actually set on the filters (0 dB everywhere when bypassed). */
export function effectiveGains(s: EqSettings): number[] {
  return EQ_FREQUENCIES.map((_, i) => (s.enabled ? clampDb(s.gains[i] ?? 0) : 0));
}

export function normalizeEq(raw: unknown): EqSettings {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Partial<EqSettings>;
  const gains = Array.isArray(r.gains) && r.gains.length === EQ_FREQUENCIES.length ? r.gains.map((g) => clampDb(Number(g))) : [...DEFAULT_EQ.gains];
  return {
    enabled: typeof r.enabled === 'boolean' ? r.enabled : DEFAULT_EQ.enabled,
    preset: typeof r.preset === 'string' ? r.preset : matchPreset(gains) ?? 'Custom',
    gains,
    preamp: clampDb(Number(r.preamp ?? 0)),
  };
}

const EQ_KEY = 'streamero.web.eq';

export function loadEq(storage: Pick<Storage, 'getItem'> = localStorage): EqSettings {
  try {
    const v = storage.getItem(EQ_KEY);
    return v ? normalizeEq(JSON.parse(v)) : { ...DEFAULT_EQ, gains: [...DEFAULT_EQ.gains] };
  } catch {
    return { ...DEFAULT_EQ, gains: [...DEFAULT_EQ.gains] };
  }
}

export function saveEq(s: EqSettings, storage: Pick<Storage, 'setItem'> = localStorage) {
  try {
    storage.setItem(EQ_KEY, JSON.stringify(s));
  } catch {
    /* ignore */
  }
}

export const formatFreq = (f: number) => (f >= 1000 ? `${f / 1000}k` : String(f));
