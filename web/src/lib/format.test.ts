import { describe, expect, it } from 'vitest';
import { needsCors } from '../player/engine';
import { compactNumber, describeDevice, formatDuration, formatTime, greetingFor, ListeningSession } from './format';
import { streamMime } from '../player/player';

describe('formatting', () => {
  it('formats times and durations', () => {
    expect(formatTime(0)).toBe('0:00');
    expect(formatTime(266.4)).toBe('4:26');
    expect(formatTime(3725)).toBe('1:02:05');
    expect(formatTime(NaN)).toBe('0:00');
    expect(formatDuration(45 * 60000)).toBe('45 min');
    expect(formatDuration(135 * 60000)).toBe('2 h 15 min');
  });

  it('formats follower counts like the mockups', () => {
    expect(compactNumber(950)).toBe('950');
    expect(compactNumber(23_100_000)).toBe('23.1M');
    expect(compactNumber(7_920_000)).toBe('7.92M');
    expect(compactNumber(180_000_000_000)).toBe('180B');
    expect(compactNumber(null)).toBe('0');
  });

  it('greets by time of day', () => {
    expect(greetingFor(8, 'Ana')).toBe('Good morning, Ana');
    expect(greetingFor(14)).toBe('Good afternoon');
    expect(greetingFor(21)).toBe('Good evening');
  });
});

describe('ListeningSession', () => {
  it('counts only time actually played and skips accidental plays', () => {
    const s = new ListeningSession('t1', 1000, { type: 'album', id: '2f1c9a3e-8b7d-4c6e-9f00-1234567890ab' });
    s.resume(1000);
    s.pause(31_000);
    s.resume(40_000);
    const ev = s.finish(true, 'web-1', 50_000)!;
    expect(ev.durationPlayedMs).toBe(40_000);
    expect(ev).toMatchObject({ trackId: 't1', completed: true, contextType: 'album', contextId: '2f1c9a3e-8b7d-4c6e-9f00-1234567890ab', deviceId: 'web-1' });
    expect(ev.playedAt).toBe(new Date(1000).toISOString());
    const short = new ListeningSession('t2', 0);
    short.resume(0);
    expect(short.finish(false, 'd', 500)).toBeNull();
  });

  it('drops non-UUID context ids (mix ids like "genre:rock")', () => {
    const s = new ListeningSession('t', 0, { type: 'mix', id: 'genre:rock' });
    s.resume(0);
    expect(s.finish(false, 'd', 5000)!.contextId).toBeUndefined();
  });
});

describe('needsCors', () => {
  it('detects cross-origin media URLs', () => {
    expect(needsCors('/v1/media/x', 'https://app.streamero.net')).toBe(false);
    expect(needsCors('https://app.streamero.net/v1/media/x', 'https://app.streamero.net')).toBe(false);
    expect(needsCors('https://cdn.example.com/a.m4a', 'https://app.streamero.net')).toBe(true);
  });
});

describe('devices and codecs', () => {
  it('describes sessions', () => {
    expect(describeDevice('Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) HeadlessChrome/141.0 Safari/537.36')).toBe('Chrome on Linux');
    expect(describeDevice('Mozilla/5.0 (Macintosh; Intel Mac OS X 14_5) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15')).toBe('Safari on macOS');
    expect(describeDevice('STREAMERO-iOS')).toBe('STREAMERO-iOS');
    expect(describeDevice(null)).toBe('Unknown device');
  });
  it('adds codec parameters to stream MIME types', () => {
    expect(streamMime({ mimeType: 'audio/mp4', delivery: { codec: 'alac', lossless: true } })).toBe('audio/mp4; codecs="alac"');
    expect(streamMime({ mimeType: 'audio/mp4', delivery: { codec: 'aac', lossless: false } })).toBe('audio/mp4; codecs="mp4a.40.2"');
    expect(streamMime({ mimeType: 'audio/mpeg', delivery: { codec: null, lossless: false } })).toBe('audio/mpeg');
  });
});
