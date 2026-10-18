import { describe, expect, it } from 'vitest';
import { diversify } from '../../src/recommendations/recommendations.service.js';
import { greeting } from '../../src/home/home.service.js';
import { loadConfig } from '../../src/config/config.js';

describe('recommendations', () => {
  it('limits consecutive tracks per artist', () => {
    const items = ['a', 'a', 'a', 'a', 'b', 'c', 'a', 'd'].map((artist, i) => ({ i, track: { artist: { id: artist } } }));
    const out = diversify(items, 6);
    expect(out.map((x) => x.track.artist.id)).toEqual(['a', 'a', 'b', 'c', 'd', 'a']);
  });

  it('greets by time of day', () => {
    expect(greeting(8, 'Ana Marić')).toBe('Good morning, Ana');
    expect(greeting(20)).toBe('Good evening');
  });
});

describe('configuration', () => {
  const base = { DATABASE_URL: 'postgres://x', JWT_ACCESS_SECRET: 'a'.repeat(32), MEDIA_SIGNING_SECRET: 'b'.repeat(32) };
  it('validates and rejects unsafe production settings', () => {
    expect(loadConfig(base as any).PORT).toBe(8080);
    expect(() => loadConfig({ ...base, JWT_ACCESS_SECRET: 'short' } as any)).toThrow(/at least 32/);
    expect(() =>
      loadConfig({ ...base, NODE_ENV: 'production', JWT_ACCESS_SECRET: 'change-me-' + 'x'.repeat(30), PUBLIC_BASE_URL: 'https://a.com' } as any),
    ).toThrow(/Placeholder secrets/);
    expect(() => loadConfig({ ...base, NODE_ENV: 'production', PUBLIC_BASE_URL: 'http://a.com' } as any)).toThrow(/https/);
    expect(() => loadConfig({ ...base, STORAGE_DRIVER: 's3' } as any)).toThrow(/S3 credentials/);
  });
});
