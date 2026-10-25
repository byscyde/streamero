import { describe, expect, it } from 'vitest';
import { applyConfig, arrangeHomeSections, configToCssVars, DEFAULT_CONFIG, genreGradient, mergeConfig, shade, TITLE_FONTS } from './appearance';
import { syncDiff } from './format';
import type { HomeSection } from './types';

describe('appearance config', () => {
  it('merges partial documents over the defaults and rejects invalid values', () => {
    const c = mergeConfig({
      version: 'v2',
      theme: { accent: '#00FF88', background: 'red', cornerRadius: 99, titleFont: 'comic', genreGradients: false },
      features: { videos: false, unknown: true },
      home: { chips: ['Music', 3] },
    });
    expect(c.version).toBe('v2');
    expect(c.theme.accent).toBe('#00FF88');
    expect(c.theme.background).toBe(DEFAULT_CONFIG.theme.background); // not #RRGGBB → default
    expect(c.theme.cornerRadius).toBe(28);
    expect(c.theme.titleFont).toBe('mono');
    expect(c.theme.genreGradients).toBe(false);
    expect(c.features.videos).toBe(false);
    expect(c.features.lyrics).toBe(true);
    expect(c.home.chips).toEqual(['Music']);
    expect(mergeConfig(null)).toEqual(DEFAULT_CONFIG);
  });

  it('maps the theme to CSS variables', () => {
    const c = mergeConfig({ theme: { accent: '#E31E2D', textSecondary: '#A1A1AA', cornerRadius: 16, titleFont: 'rounded' } });
    const v = configToCssVars(c);
    expect(v['--accent']).toBe('#E31E2D');
    expect(v['--bg']).toBe('#0E0E10');
    expect(v['--surface']).toBe('#18181B');
    expect(v['--surface-raised']).toBe('#232327');
    expect(v['--border']).toBe('#3A3A40');
    expect(v['--text']).toBe('#FFFFFF');
    expect(v['--text-2']).toBe('#A1A1AA');
    expect(v['--on-accent']).toBe('#FFFFFF');
    expect(v['--radius']).toBe('16px');
    expect(v['--radius-sm']).toBe('8px');
    expect(v['--accent-soft']).toBe('rgba(227, 30, 45, 0.16)');
    expect(v['--title-font']).toBe(TITLE_FONTS.rounded);
  });

  it('applies variables and data attributes to the root element', () => {
    const el = document.createElement('div');
    applyConfig(mergeConfig({ theme: { accent: '#112233', genreGradients: false, playerStyle: 'solid' } }), el);
    expect(el.style.getPropertyValue('--accent')).toBe('#112233');
    expect(el.dataset.genreGradients).toBe('false');
    expect(el.dataset.playerStyle).toBe('solid');
  });

  it('shades colours and gives genres stable gradients', () => {
    expect(shade('#000000', 0.5)).toBe('#808080');
    expect(shade('#FFFFFF', -1)).toBe('#000000');
    expect(genreGradient('Rock')).toBe(genreGradient('rock'));
    expect(genreGradient('Rock')).toMatch(/^linear-gradient/);
  });
});

describe('home sections', () => {
  const sec = (kind: string, items: HomeSection['items'] = [{ type: 'genre', name: kind, trackCount: 1 }]): HomeSection => ({ id: kind, kind, title: kind, layout: 'carousel', items });
  const video: HomeSection['items'][number] = { type: 'video', id: 'v', title: 'v', durationMs: 1, explicit: false, genres: [], isLiked: false };
  const feed = [sec('music_videos', [video]), sec('trending'), sec('genres'), sec('featured_playlists'), sec('mystery_kind')];

  it('orders sections by the config and keeps unknown kinds at the end', () => {
    expect(arrangeHomeSections(feed, DEFAULT_CONFIG).map((s) => s.kind)).toEqual(['featured_playlists', 'genres', 'trending', 'music_videos', 'mystery_kind']);
  });

  it('hides sections removed from the order and video sections when videos are off', () => {
    const c = mergeConfig({ home: { sectionsOrder: ['genres', 'music_videos'] }, features: { videos: false } });
    expect(arrangeHomeSections(feed, c).map((s) => s.kind)).toEqual(['genres', 'mystery_kind']);
  });

  it('filters by chip', () => {
    expect(arrangeHomeSections(feed, DEFAULT_CONFIG, 'Videos').map((s) => s.kind)).toEqual(['music_videos']);
    expect(arrangeHomeSections(feed, DEFAULT_CONFIG, 'Music').map((s) => s.kind)).not.toContain('music_videos');
  });
});

describe('sync diff', () => {
  it('records a baseline first, then reports changes per area', () => {
    const a = { catalogVersion: 'c1', libraryVersion: 'l1', configVersion: 'x1' };
    expect(syncDiff(null, a)).toEqual({ catalog: false, library: false, config: false });
    expect(syncDiff(a, { ...a, libraryVersion: 'l2' })).toEqual({ catalog: false, library: true, config: false });
    expect(syncDiff(a, { ...a, configVersion: 'x2', catalogVersion: 'c2' })).toEqual({ catalog: true, library: false, config: true });
  });
});
