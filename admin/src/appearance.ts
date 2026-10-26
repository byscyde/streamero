/** Appearance / remote-config document (docs/APP_CONFIG.md §1) plus pure helpers used by the editor. */

export type TitleFont = 'mono' | 'default' | 'rounded';
export type PlayerStyle = 'artwork' | 'solid';
export type AnnouncementStyle = 'info' | 'warning' | 'success';
export type HomeChip = 'All' | 'Music' | 'Videos';

export interface Appearance {
  version?: string;
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
    titleFont: TitleFont;
    cornerRadius: number;
    genreGradients: boolean;
    playerStyle: PlayerStyle;
  };
  texts: { welcomeTitle: string; welcomeSubtitle: string; homeGreeting: boolean };
  home: { chips: HomeChip[]; sectionsOrder: string[] };
  features: {
    videos: boolean;
    youtube: boolean;
    lyrics: boolean;
    downloads: boolean;
    equalizer: boolean;
    radio: boolean;
    signup: boolean;
    googleSignIn: boolean;
  };
  announcement: { enabled: boolean; text: string; style: AnnouncementStyle };
}

/** Client-side copy of the defaults; the server's `defaults` (GET /v1/admin/appearance) wins when present. */
export const DEFAULT_APPEARANCE: Appearance = {
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
    welcomeSubtitle: 'Use your email or Google account to continue with STREAMERO.',
    homeGreeting: true,
  },
  home: {
    chips: ['All', 'Music', 'Videos'],
    sectionsOrder: ['recommended_playlists', 'genres', 'top_artists', 'new_albums', 'popular_singles', 'recently_played', 'made_for_you', 'music_videos'],
  },
  features: { videos: true, youtube: true, lyrics: true, downloads: true, equalizer: true, radio: true, signup: true, googleSignIn: true },
  announcement: { enabled: false, text: '', style: 'info' },
};

export const ALL_CHIPS: HomeChip[] = ['All', 'Music', 'Videos'];

export const SECTION_LABELS: Record<string, string> = {
  recommended_playlists: 'Recommended playlists',
  genres: 'Genres',
  top_artists: 'Top artists',
  new_albums: 'New albums',
  popular_singles: 'Popular singles',
  recently_played: 'Recently played',
  made_for_you: 'Made for you',
  music_videos: 'Music videos',
};

export const COLOR_FIELDS: { key: keyof Appearance['theme']; label: string; hint: string }[] = [
  { key: 'accent', label: 'Accent', hint: 'Primary buttons, active states, progress' },
  { key: 'onAccent', label: 'On accent', hint: 'Text and icons on the accent colour' },
  { key: 'background', label: 'Background', hint: 'App background' },
  { key: 'surface', label: 'Surface', hint: 'Cards, rows, mini player' },
  { key: 'surfaceRaised', label: 'Raised surface', hint: 'Inputs, chips, sheets' },
  { key: 'border', label: 'Border', hint: 'Outline pills (More, Shuffle, Radio)' },
  { key: 'textPrimary', label: 'Primary text', hint: 'Titles and body text' },
  { key: 'textSecondary', label: 'Secondary text', hint: 'Subtitles, metadata' },
];

export const FEATURE_LABELS: Record<keyof Appearance['features'], { label: string; hint: string }> = {
  videos: { label: 'Videos', hint: 'Video tab, music videos and the "Videos" chip' },
  youtube: { label: 'YouTube discovery', hint: 'YouTube search results via the official embedded player' },
  lyrics: { label: 'Lyrics', hint: 'Lyrics view in the player' },
  downloads: { label: 'Offline downloads', hint: 'Download buttons in the apps' },
  equalizer: { label: 'Equalizer', hint: 'Equalizer settings' },
  radio: { label: 'Radio', hint: 'Artist and track radio' },
  signup: { label: 'Sign-up', hint: 'New accounts can register themselves' },
  googleSignIn: {
    label: 'Google sign-in',
    hint: '“Continue with Google” on the welcome and log-in screens. Also requires GOOGLE_WEB_CLIENT_ID / GOOGLE_IOS_CLIENT_ID in the server .env',
  },
};

/** Text length limits enforced in the form (kept conservative; the server validates too). */
export const TEXT_LIMITS = {
  appName: 40,
  tagline: 120,
  developer: 60,
  developerUrl: 200,
  supportEmail: 200,
  welcomeTitle: 200,
  welcomeSubtitle: 300,
  announcement: 500,
} as const;

const HEX = /^#[0-9A-Fa-f]{6}$/;

export function isHexColor(v: unknown): v is string {
  return typeof v === 'string' && HEX.test(v);
}

/**
 * Normalises user-typed colours to `#RRGGBB` (upper case). Accepts `RRGGBB`, `#RGB` and `RGB`.
 * Returns null when the input cannot be a colour.
 */
export function normalizeHex(input: string): string | null {
  let s = input.trim();
  if (!s.startsWith('#')) s = `#${s}`;
  if (/^#[0-9A-Fa-f]{3}$/.test(s)) s = `#${s[1]}${s[1]}${s[2]}${s[2]}${s[3]}${s[3]}`;
  return HEX.test(s) ? s.toUpperCase() : null;
}

const isObj = (v: unknown): v is Record<string, unknown> => !!v && typeof v === 'object' && !Array.isArray(v);

/** Deep merge: objects are merged key by key, arrays and scalars from `over` replace those in `base`. */
export function deepMerge<T>(base: T, over: unknown): T {
  if (!isObj(base) || !isObj(over)) return (over === undefined ? base : (over as T));
  const out: Record<string, unknown> = { ...base };
  for (const [k, v] of Object.entries(over)) {
    if (v === undefined) continue;
    out[k] = isObj(out[k]) && isObj(v) ? deepMerge(out[k], v) : v;
  }
  return out as T;
}

const SECTIONS = ['brand', 'theme', 'texts', 'home', 'features', 'announcement'] as const;

/** Keeps only the editable sections and, inside each, only the keys this editor knows (the server rejects unknown keys). */
function pruneToSchema(doc: Record<string, unknown>): Omit<Appearance, 'version'> {
  const out: Record<string, unknown> = {};
  for (const sec of SECTIONS) {
    const src = isObj(doc[sec]) ? (doc[sec] as Record<string, unknown>) : {};
    const known = DEFAULT_APPEARANCE[sec] as Record<string, unknown>;
    const pruned: Record<string, unknown> = {};
    for (const k of Object.keys(known)) pruned[k] = k in src ? src[k] : known[k];
    out[sec] = pruned;
  }
  return out as unknown as Omit<Appearance, 'version'>;
}

/**
 * Builds a complete document from whatever the server returned, falling back to the defaults. Unknown
 * top-level keys (`defaults`, the read-only `auth` block) and retired keys such as `features.appleSignIn`
 * are dropped.
 */
export function mergeAppearance(doc: unknown, defaults: Appearance = DEFAULT_APPEARANCE): Appearance {
  const merged = deepMerge(structuredClone(defaults), isObj(doc) ? doc : {}) as Appearance & Record<string, unknown>;
  const version = merged.version;
  return { ...(version ? { version } : {}), ...pruneToSchema(merged) };
}

/** Body for PUT /v1/admin/appearance: the editable document without `version`, `defaults` or `auth`. */
export function toSaveBody(a: Appearance): Omit<Appearance, 'version'> {
  return structuredClone(pruneToSchema(a as unknown as Record<string, unknown>));
}

/** Lists leaf paths whose values differ (arrays are compared as a whole). `version` is ignored. */
export function diffAppearance(a: unknown, b: unknown, prefix = ''): string[] {
  if (isObj(a) && isObj(b)) {
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    const out: string[] = [];
    for (const k of keys) {
      if (!prefix && k === 'version') continue;
      out.push(...diffAppearance(a[k], b[k], prefix ? `${prefix}.${k}` : k));
    }
    return out;
  }
  return JSON.stringify(a) === JSON.stringify(b) ? [] : [prefix || '(root)'];
}

/** Moves item `i` by `delta` positions (clamped); returns a new array. */
export function moveItem<T>(arr: readonly T[], i: number, delta: number): T[] {
  const j = Math.max(0, Math.min(arr.length - 1, i + delta));
  if (i === j || i < 0 || i >= arr.length) return [...arr];
  const next = [...arr];
  const [x] = next.splice(i, 1);
  next.splice(j, 0, x);
  return next;
}

/** Toggles a home chip while keeping the canonical relative order of newly added chips at the end. */
export function toggleChip(chips: readonly HomeChip[], chip: HomeChip, on: boolean): HomeChip[] {
  if (on) return chips.includes(chip) ? [...chips] : [...chips, chip];
  return chips.filter((c) => c !== chip);
}

const isEmail = (s: string) => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(s);
const isHttpUrl = (s: string) => {
  try {
    const u = new URL(s);
    return u.protocol === 'https:' || u.protocol === 'http:';
  } catch {
    return false;
  }
};

/** Validates the document; returns a map of field path → message. Empty map = valid. */
export function validateAppearance(a: Appearance): Record<string, string> {
  const e: Record<string, string> = {};
  const len = (path: string, v: string, max: number, required = true) => {
    if (required && !v.trim()) e[path] = 'Required';
    else if (v.length > max) e[path] = `At most ${max} characters`;
  };
  len('brand.appName', a.brand.appName, TEXT_LIMITS.appName);
  len('brand.tagline', a.brand.tagline, TEXT_LIMITS.tagline, false);
  len('brand.developer', a.brand.developer, TEXT_LIMITS.developer, false);
  len('brand.developerUrl', a.brand.developerUrl, TEXT_LIMITS.developerUrl, false);
  if (a.brand.developerUrl && !e['brand.developerUrl'] && !isHttpUrl(a.brand.developerUrl)) e['brand.developerUrl'] = 'Must be an http(s) URL';
  len('brand.supportEmail', a.brand.supportEmail, TEXT_LIMITS.supportEmail, false);
  if (a.brand.supportEmail && !e['brand.supportEmail'] && !isEmail(a.brand.supportEmail)) e['brand.supportEmail'] = 'Must be an email address';
  for (const { key } of COLOR_FIELDS) if (!isHexColor(a.theme[key])) e[`theme.${key}`] = 'Use #RRGGBB';
  if (!['mono', 'default', 'rounded'].includes(a.theme.titleFont)) e['theme.titleFont'] = 'Invalid font';
  if (!Number.isInteger(a.theme.cornerRadius) || a.theme.cornerRadius < 0 || a.theme.cornerRadius > 28) e['theme.cornerRadius'] = 'Whole number 0–28';
  if (!['artwork', 'solid'].includes(a.theme.playerStyle)) e['theme.playerStyle'] = 'Invalid player style';
  len('texts.welcomeTitle', a.texts.welcomeTitle, TEXT_LIMITS.welcomeTitle);
  len('texts.welcomeSubtitle', a.texts.welcomeSubtitle, TEXT_LIMITS.welcomeSubtitle, false);
  if (!a.home.chips.length) e['home.chips'] = 'Enable at least one chip';
  else if (a.home.chips.some((c) => !ALL_CHIPS.includes(c)) || new Set(a.home.chips).size !== a.home.chips.length) e['home.chips'] = 'Invalid chips';
  if (new Set(a.home.sectionsOrder).size !== a.home.sectionsOrder.length) e['home.sectionsOrder'] = 'Duplicate sections';
  if (a.announcement.text.length > TEXT_LIMITS.announcement) e['announcement.text'] = `At most ${TEXT_LIMITS.announcement} characters`;
  if (a.announcement.enabled && !a.announcement.text.trim()) e['announcement.text'] = 'Write the announcement or switch it off';
  if (!['info', 'warning', 'success'].includes(a.announcement.style)) e['announcement.style'] = 'Invalid style';
  return e;
}

/** Relative luminance contrast ratio (WCAG) between two #RRGGBB colours. */
export function contrastRatio(a: string, b: string): number {
  const lum = (hex: string) => {
    const [r, g, bl] = [1, 3, 5].map((i) => {
      const c = parseInt(hex.slice(i, i + 2), 16) / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * bl;
  };
  const [x, y] = [lum(a), lum(b)].sort((m, n) => n - m);
  return (x + 0.05) / (y + 0.05);
}

export const FONT_STACKS: Record<TitleFont, string> = {
  mono: "'JetBrains Mono','SF Mono',Menlo,monospace",
  default: "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif",
  rounded: "ui-rounded,'SF Pro Rounded','Nunito','Varela Round',-apple-system,sans-serif",
};
