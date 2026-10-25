import { createHash } from 'node:crypto';
import { z } from 'zod';

/** Contract: docs/APP_CONFIG.md §1. Keep field names and defaults in sync with that document. */

export const HOME_CHIPS = ['All', 'Music', 'Videos'] as const;
export const HOME_SECTIONS = [
  'recommended_playlists',
  'genres',
  'top_artists',
  'new_albums',
  'popular_singles',
  'recently_played',
  'made_for_you',
  'music_videos',
] as const;

export const DEFAULT_APPEARANCE = {
  brand: {
    appName: 'STREAMERO',
    tagline: 'Your Sound. Your Screen. Your World.',
    developer: 'SCYDE',
    developerUrl: 'https://scyde.dev',
    supportEmail: 'no-reply@scyde.dev',
  },
  theme: {
    accent: '#E31E2D',
    onAccent: '#FFFFFF',
    background: '#0E0E10',
    surface: '#18181B',
    surfaceRaised: '#232327',
    border: '#3A3A40',
    textPrimary: '#FFFFFF',
    textSecondary: '#A1A1AA',
    titleFont: 'mono' as 'mono' | 'default' | 'rounded',
    cornerRadius: 12,
    genreGradients: true,
    playerStyle: 'artwork' as 'artwork' | 'solid',
  },
  texts: {
    welcomeTitle: 'Discover your music,\npersonalize your experience',
    welcomeSubtitle: 'Use your email or Apple ID to continue with STREAMERO.',
    homeGreeting: true,
  },
  home: {
    chips: [...HOME_CHIPS] as string[],
    sectionsOrder: [...HOME_SECTIONS] as string[],
  },
  features: {
    videos: true,
    youtube: true,
    lyrics: true,
    downloads: true,
    equalizer: true,
    radio: true,
    signup: true,
    appleSignIn: true,
  },
  announcement: { enabled: false, text: '', style: 'info' as 'info' | 'warning' | 'success' },
};

export type AppearanceDocument = typeof DEFAULT_APPEARANCE;
export type AppearanceResponse = AppearanceDocument & { version: string };

const colour = z.string().regex(/^#[0-9A-Fa-f]{6}$/, 'Colour must be #RRGGBB');
const text = (min: number, max: number) => z.string().min(min).max(max);
const unique = <T>(arr: T[]) => new Set(arr).size === arr.length;

/** Per-section schemas (complete documents). Unknown keys are rejected. */
const FULL_SECTIONS = {
  brand: z
    .object({
      appName: text(1, 40),
      tagline: text(0, 120),
      developer: text(0, 60),
      developerUrl: z.union([z.literal(''), z.string().max(200).url().refine((u) => /^https?:\/\//i.test(u), 'Must be an http(s) URL')]),
      supportEmail: z.union([z.literal(''), z.string().max(254).email()]),
    })
    .strict(),
  theme: z
    .object({
      accent: colour,
      onAccent: colour,
      background: colour,
      surface: colour,
      surfaceRaised: colour,
      border: colour,
      textPrimary: colour,
      textSecondary: colour,
      titleFont: z.enum(['mono', 'default', 'rounded']),
      cornerRadius: z.number().int().min(0).max(28),
      genreGradients: z.boolean(),
      playerStyle: z.enum(['artwork', 'solid']),
    })
    .strict(),
  texts: z
    .object({
      welcomeTitle: text(0, 120),
      welcomeSubtitle: text(0, 240),
      homeGreeting: z.boolean(),
    })
    .strict(),
  home: z
    .object({
      chips: z.array(z.enum(HOME_CHIPS)).min(1).max(HOME_CHIPS.length).refine(unique, 'Chips must be unique'),
      sectionsOrder: z.array(z.enum(HOME_SECTIONS)).max(HOME_SECTIONS.length).refine(unique, 'Sections must be unique'),
    })
    .strict(),
  features: z
    .object({
      videos: z.boolean(),
      youtube: z.boolean(),
      lyrics: z.boolean(),
      downloads: z.boolean(),
      equalizer: z.boolean(),
      radio: z.boolean(),
      signup: z.boolean(),
      appleSignIn: z.boolean(),
    })
    .strict(),
  announcement: z
    .object({
      enabled: z.boolean(),
      text: text(0, 500),
      style: z.enum(['info', 'warning', 'success']),
    })
    .strict(),
};

/** Partial sections: every field optional (partial PUT), unknown keys still rejected. */
const SECTIONS = {
  brand: FULL_SECTIONS.brand.partial().strict(),
  theme: FULL_SECTIONS.theme.partial().strict(),
  texts: FULL_SECTIONS.texts.partial().strict(),
  home: FULL_SECTIONS.home.partial().strict(),
  features: FULL_SECTIONS.features.partial().strict(),
  announcement: FULL_SECTIONS.announcement.partial().strict(),
};

/** PUT body: every section optional, unknown sections rejected. */
export const appearancePatchSchema = z.object(SECTIONS).partial().strict();

/** Response document (for OpenAPI): every field present. */
export const appearanceDocumentSchema = z.object({ version: z.string(), ...FULL_SECTIONS });

export type AppearancePatch = z.infer<typeof appearancePatchSchema>;

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Deep merge for plain objects; arrays and scalars from `over` replace `base`. Keys not in `base` are dropped. */
export function deepMerge<T>(base: T, over: unknown): T {
  if (!isPlainObject(base) || !isPlainObject(over)) return (over === undefined ? base : (over as T));
  const out: Record<string, unknown> = { ...base };
  for (const key of Object.keys(base)) {
    if (over[key] === undefined) continue;
    const b = (base as Record<string, unknown>)[key];
    out[key] = isPlainObject(b) ? deepMerge(b, over[key]) : over[key];
  }
  return out as T;
}

/**
 * Merges stored values over the defaults. Stored values that no longer validate (e.g. after a schema change)
 * are ignored field by field, so a bad row can never break clients.
 */
export function mergeAppearance(stored: unknown): AppearanceResponse {
  const merged = deepMerge(DEFAULT_APPEARANCE, sanitiseStored(stored));
  return { version: appearanceVersion(merged), ...merged };
}

function sanitiseStored(stored: unknown): AppearancePatch {
  if (!isPlainObject(stored)) return {};
  const whole = appearancePatchSchema.safeParse(stored);
  if (whole.success) return whole.data;
  const out: Record<string, Record<string, unknown>> = {};
  for (const [section, value] of Object.entries(stored)) {
    const sectionSchema = (SECTIONS as Record<string, z.ZodObject<any>>)[section];
    if (!sectionSchema || !isPlainObject(value)) continue;
    for (const [field, v] of Object.entries(value)) {
      if (!(field in sectionSchema.shape)) continue;
      const one = sectionSchema.safeParse({ [field]: v });
      if (one.success) (out[section] ??= {})[field] = (one.data as Record<string, unknown>)[field];
    }
  }
  return out as AppearancePatch;
}

/** Short, stable hash of the merged document (key order is fixed by the defaults object). */
export function appearanceVersion(doc: AppearanceDocument): string {
  return createHash('sha256').update(JSON.stringify(doc)).digest('hex').slice(0, 16);
}
