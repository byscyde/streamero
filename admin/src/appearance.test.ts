import { describe, expect, it } from 'vitest';
import {
  contrastRatio, DEFAULT_APPEARANCE, deepMerge, diffAppearance, isHexColor, mergeAppearance, moveItem, normalizeHex, toggleChip, toSaveBody, validateAppearance,
} from './appearance';

const clone = () => structuredClone(DEFAULT_APPEARANCE);

describe('colour helpers', () => {
  it('validates strict #RRGGBB', () => {
    expect(isHexColor('#E31E2D')).toBe(true);
    expect(isHexColor('#e31e2d')).toBe(true);
    expect(isHexColor('E31E2D')).toBe(false);
    expect(isHexColor('#FFF')).toBe(false);
    expect(isHexColor('#GGGGGG')).toBe(false);
    expect(isHexColor(123)).toBe(false);
  });
  it('normalises typed colours', () => {
    expect(normalizeHex('e31e2d')).toBe('#E31E2D');
    expect(normalizeHex(' #abc ')).toBe('#AABBCC');
    expect(normalizeHex('fff')).toBe('#FFFFFF');
    expect(normalizeHex('#12345')).toBeNull();
    expect(normalizeHex('red')).toBeNull();
  });
  it('computes WCAG contrast', () => {
    expect(contrastRatio('#FFFFFF', '#000000')).toBeCloseTo(21, 0);
    expect(contrastRatio('#777777', '#777777')).toBeCloseTo(1, 5);
  });
});

describe('merge / diff', () => {
  it('deep merges objects and replaces arrays', () => {
    expect(deepMerge({ a: { b: 1, c: 2 }, l: [1, 2] }, { a: { c: 3 }, l: [9] })).toEqual({ a: { b: 1, c: 3 }, l: [9] });
    expect(deepMerge({ a: 1 }, { a: undefined })).toEqual({ a: 1 });
  });
  it('fills a partial server document with defaults and drops unknown top-level keys', () => {
    const m = mergeAppearance({ version: 'v1', theme: { accent: '#00FF00' }, defaults: { x: 1 }, home: { chips: ['Music'] } });
    expect(m.version).toBe('v1');
    expect(m.theme.accent).toBe('#00FF00');
    expect(m.theme.background).toBe('#0E0E10');
    expect(m.home.chips).toEqual(['Music']);
    expect(m.home.sectionsOrder).toHaveLength(8);
    expect('defaults' in m).toBe(false);
    expect(mergeAppearance(null)).toEqual(DEFAULT_APPEARANCE);
  });
  it('does not mutate the defaults', () => {
    const m = mergeAppearance({});
    m.theme.accent = '#000000';
    expect(DEFAULT_APPEARANCE.theme.accent).toBe('#E31E2D');
  });
  it('lists changed paths, ignoring version', () => {
    const a = { ...clone(), version: 'a' };
    const b = { ...clone(), version: 'b' };
    expect(diffAppearance(a, b)).toEqual([]);
    b.theme.cornerRadius = 20;
    b.home.chips = ['Videos', 'All'];
    b.features.radio = false;
    expect(diffAppearance(a, b).sort()).toEqual(['features.radio', 'home.chips', 'theme.cornerRadius']);
  });
  it('save body omits version', () => {
    const body = toSaveBody({ ...clone(), version: 'x' });
    expect('version' in body).toBe(false);
    expect(body.theme.accent).toBe('#E31E2D');
  });
});

describe('ordering helpers', () => {
  it('moves items with clamping', () => {
    expect(moveItem(['a', 'b', 'c'], 0, 1)).toEqual(['b', 'a', 'c']);
    expect(moveItem(['a', 'b', 'c'], 2, -1)).toEqual(['a', 'c', 'b']);
    expect(moveItem(['a', 'b', 'c'], 0, -1)).toEqual(['a', 'b', 'c']);
    expect(moveItem(['a', 'b', 'c'], 2, 5)).toEqual(['a', 'b', 'c']);
  });
  it('toggles chips', () => {
    expect(toggleChip(['All', 'Music'], 'Videos', true)).toEqual(['All', 'Music', 'Videos']);
    expect(toggleChip(['All', 'Music'], 'Music', true)).toEqual(['All', 'Music']);
    expect(toggleChip(['All', 'Music'], 'All', false)).toEqual(['Music']);
  });
});

describe('validation', () => {
  it('accepts the defaults', () => {
    expect(validateAppearance(clone())).toEqual({});
  });
  it('flags bad values', () => {
    const a = clone();
    a.theme.accent = '#ZZZ';
    a.theme.cornerRadius = 40;
    a.brand.appName = ' ';
    a.brand.developerUrl = 'javascript:alert(1)';
    a.brand.supportEmail = 'nope';
    a.home.chips = [];
    a.announcement.enabled = true;
    a.announcement.text = '';
    const e = validateAppearance(a);
    expect(Object.keys(e).sort()).toEqual(['announcement.text', 'brand.appName', 'brand.developerUrl', 'brand.supportEmail', 'home.chips', 'theme.accent', 'theme.cornerRadius']);
  });
  it('rejects duplicate chips and sections', () => {
    const a = clone();
    a.home.chips = ['All', 'All'];
    a.home.sectionsOrder = ['genres', 'genres'];
    expect(validateAppearance(a)).toMatchObject({ 'home.chips': expect.any(String), 'home.sectionsOrder': expect.any(String) });
  });
});
