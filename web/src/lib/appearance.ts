/** Remote appearance config (docs/APP_CONFIG.md §1) and its mapping to CSS custom properties. */
import type { HomeSection } from './types';

export interface AppConfig {
  version: string;
  brand: { appName: string; tagline: string; developer: string; developerUrl: string; supportEmail: string };
  theme: {
    accent: string;
    onAccent: string;
    background: string;
    surface: string;
    surfaceRaised: string;
    border: string;
    textPrimary: string;
    textSecondary: string;
    titleFont: 'mono' | 'default' | 'rounded';
    cornerRadius: number;
    genreGradients: boolean;
    playerStyle: 'artwork' | 'solid';
  };
  texts: { welcomeTitle: string; welcomeSubtitle: string; homeGreeting: boolean };
  home: { chips: string[]; sectionsOrder: string[] };
  features: {
    videos: boolean;
    youtube: boolean;
    lyrics: boolean;
    downloads: boolean;
    equalizer: boolean;
    radio: boolean;
    signup: boolean;
    appleSignIn: boolean;
  };
  announcement: { enabled: boolean; text: string; style: 'info' | 'warning' | 'success' };
}

export const DEFAULT_CONFIG: AppConfig = {
  version: 'default',
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
    titleFont: 'mono',
    cornerRadius: 12,
    genreGradients: true,
    playerStyle: 'artwork',
  },
  texts: {
    welcomeTitle: 'Discover your music,\npersonalize your experience',
    welcomeSubtitle: 'Use your email or Apple ID to continue with STREAMERO.',
    homeGreeting: true,
  },
  home: {
    chips: ['All', 'Music', 'Videos'],
    sectionsOrder: ['recommended_playlists', 'genres', 'top_artists', 'new_albums', 'popular_singles', 'recently_played', 'made_for_you', 'music_videos'],
  },
  features: { videos: true, youtube: true, lyrics: true, downloads: true, equalizer: true, radio: true, signup: true, appleSignIn: true },
  announcement: { enabled: false, text: '', style: 'info' },
};

const HEX = /^#[0-9a-fA-F]{6}$/;

/** Merges a (possibly partial or malformed) server document over the defaults, field by field. */
export function mergeConfig(raw: unknown): AppConfig {
  const r = (raw && typeof raw === 'object' ? raw : {}) as Record<string, any>;
  const pick = <T extends Record<string, unknown>>(def: T, src: unknown): T => {
    const s = (src && typeof src === 'object' ? src : {}) as Record<string, unknown>;
    const out = { ...def } as Record<string, unknown>;
    for (const k of Object.keys(def)) {
      const dv = def[k];
      const sv = s[k];
      if (sv === undefined || sv === null) continue;
      if (Array.isArray(dv)) {
        if (Array.isArray(sv)) out[k] = sv.filter((x) => typeof x === 'string');
      } else if (typeof dv === typeof sv) {
        if (typeof dv === 'string' && HEX.test(dv) && !HEX.test(sv as string)) continue; // reject bad colours
        out[k] = sv;
      }
    }
    return out as T;
  };
  const theme = pick(DEFAULT_CONFIG.theme, r.theme);
  theme.cornerRadius = Math.max(0, Math.min(28, Math.round(theme.cornerRadius)));
  if (!['mono', 'default', 'rounded'].includes(theme.titleFont)) theme.titleFont = 'mono';
  return {
    version: typeof r.version === 'string' ? r.version : DEFAULT_CONFIG.version,
    brand: pick(DEFAULT_CONFIG.brand, r.brand),
    theme,
    texts: pick(DEFAULT_CONFIG.texts, r.texts),
    home: pick(DEFAULT_CONFIG.home, r.home),
    features: pick(DEFAULT_CONFIG.features, r.features),
    announcement: pick(DEFAULT_CONFIG.announcement, r.announcement),
  };
}

export const TITLE_FONTS: Record<AppConfig['theme']['titleFont'], string> = {
  mono: "'JetBrains Mono', 'SF Mono', ui-monospace, Menlo, Consolas, 'Liberation Mono', monospace",
  default: "system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif",
  rounded: "ui-rounded, 'SF Pro Rounded', 'Nunito', 'Varela Round', system-ui, sans-serif",
};

function hexToRgb(hex: string): [number, number, number] {
  const n = parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/** Mixes `hex` towards white (amount > 0) or black (amount < 0). */
export function shade(hex: string, amount: number): string {
  const [r, g, b] = hexToRgb(hex);
  const t = amount < 0 ? 0 : 255;
  const p = Math.abs(amount);
  const f = (c: number) => Math.round(c + (t - c) * p).toString(16).padStart(2, '0');
  return `#${f(r)}${f(g)}${f(b)}`.toUpperCase();
}

export function rgba(hex: string, alpha: number): string {
  const [r, g, b] = hexToRgb(hex);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
}

/** CSS custom properties applied on :root. Pure so it is unit-tested. */
export function configToCssVars(c: AppConfig): Record<string, string> {
  const t = c.theme;
  return {
    '--accent': t.accent,
    '--accent-hover': shade(t.accent, 0.12),
    '--accent-soft': rgba(t.accent, 0.16),
    '--on-accent': t.onAccent,
    '--bg': t.background,
    '--bg-elevated': shade(t.background, 0.03),
    '--surface': t.surface,
    '--surface-hover': shade(t.surface, 0.06),
    '--surface-raised': t.surfaceRaised,
    '--border': t.border,
    '--text': t.textPrimary,
    '--text-2': t.textSecondary,
    '--text-3': rgba(t.textSecondary, 0.7),
    '--radius': `${t.cornerRadius}px`,
    '--radius-sm': `${Math.round(t.cornerRadius * 0.5)}px`,
    '--radius-lg': `${Math.min(32, Math.round(t.cornerRadius * 1.5))}px`,
    '--title-font': TITLE_FONTS[t.titleFont],
  };
}

export function applyConfig(c: AppConfig, root: HTMLElement = document.documentElement) {
  for (const [k, v] of Object.entries(configToCssVars(c))) root.style.setProperty(k, v);
  root.dataset.genreGradients = String(c.theme.genreGradients);
  root.dataset.playerStyle = c.theme.playerStyle;
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', c.theme.accent);
}

/** Colourful gradients for genre chips (as in the mockups). Stable per name. */
const GRADIENTS = [
  ['#7F5CFF', '#E879F9', '#60A5FA'],
  ['#B91C1C', '#7F1D1D', '#EF4444'],
  ['#1E3A8A', '#0EA5E9', '#22D3EE'],
  ['#F97316', '#FB923C', '#F43F5E'],
  ['#065F46', '#10B981', '#A3E635'],
  ['#9D174D', '#DB2777', '#F472B6'],
  ['#4C1D95', '#7C3AED', '#2563EB'],
  ['#B45309', '#F59E0B', '#FDE047'],
  ['#0F766E', '#14B8A6', '#3B82F6'],
  ['#831843', '#BE123C', '#FB7185'],
];

export function hashString(s: string): number {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return h >>> 0;
}

export function genreGradient(name: string): string {
  const [a, b, c] = GRADIENTS[hashString(name.toLowerCase()) % GRADIENTS.length];
  return `linear-gradient(120deg, ${a} 0%, ${b} 55%, ${c} 100%)`;
}

/**
 * The config's `home.sectionsOrder` uses client-level keys; `/v1/home` sections carry backend kinds.
 * Each key covers one or more kinds. Kinds not covered by any key keep the server order at the end.
 */
export const SECTION_KEY_KINDS: Record<string, string[]> = {
  recommended_playlists: ['featured_playlists', 'editorial'],
  genres: ['genres', 'moods'],
  top_artists: ['favorite_artists'],
  new_albums: ['recently_added', 'album_recommendations'],
  popular_singles: ['trending'],
  recently_played: ['continue_listening', 'recently_played'],
  made_for_you: ['made_for_you'],
  music_videos: ['music_videos', 'continue_watching'],
};

const VIDEO_KINDS = new Set(['music_videos', 'continue_watching']);

export type HomeChip = 'All' | 'Music' | 'Videos' | string;

/** Orders, hides and filters Home sections according to the config and the selected chip. */
export function arrangeHomeSections(sections: HomeSection[], c: AppConfig, chip: HomeChip = 'All'): HomeSection[] {
  const covered = new Map<string, number>();
  c.home.sectionsOrder.forEach((key, i) => (SECTION_KEY_KINDS[key] ?? []).forEach((k) => covered.has(k) || covered.set(k, i)));
  const allMapped = new Set(Object.values(SECTION_KEY_KINDS).flat());
  const out = sections
    .map((s, i) => ({ s, i }))
    .filter(({ s }) => covered.has(s.kind) || !allMapped.has(s.kind)) // a key removed from the order hides its sections
    .filter(({ s }) => c.features.videos || !VIDEO_KINDS.has(s.kind))
    .filter(({ s }) => {
      if (chip === 'Videos') return VIDEO_KINDS.has(s.kind) || s.items.some((it) => it.type === 'video');
      if (chip === 'Music') return !VIDEO_KINDS.has(s.kind);
      return true;
    })
    .sort((a, b) => (covered.get(a.s.kind) ?? 1000) - (covered.get(b.s.kind) ?? 1000) || a.i - b.i)
    .map(({ s }) => (chip === 'Music' ? { ...s, items: s.items.filter((it) => it.type !== 'video') } : s))
    .filter((s) => s.items.length > 0);
  return out;
}
