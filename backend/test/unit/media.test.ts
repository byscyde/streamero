import { describe, expect, it } from 'vitest';
import type { ProbeResult } from '../../src/media/ffmpeg.js';
import { planAudioRenditions, planVideoLadder } from '../../src/media/profiles.js';
import { chooseProfile } from '../../src/streaming/streaming.service.js';
import { parseMaster } from '../../src/ingestion/processor.js';
import { extractTrackMetadata, normaliseDate, safeFileName, splitList, toBcp47 } from '../../src/ingestion/metadata.js';

const probe = (format: string, codec: string, bitRate?: number, extra: object = {}): ProbeResult => ({
  format: { format_name: format, duration: '200', bit_rate: bitRate ? String(bitRate) : undefined },
  streams: [{ index: 0, codec_type: 'audio', codec_name: codec, channels: 2, sample_rate: '44100', bit_rate: bitRate ? String(bitRate) : undefined, ...extra }],
});

describe('audio rendition planning', () => {
  it('produces all profiles including lossless ALAC for a FLAC source', () => {
    const plan = planAudioRenditions(probe('flac', 'flac', 900_000, { bits_per_raw_sample: '24' }));
    expect(plan.map((p) => [p.profile, p.action, p.codec])).toEqual([
      ['data_saver', 'transcode', 'aac'],
      ['standard', 'transcode', 'aac'],
      ['high', 'transcode', 'aac'],
      ['lossless', 'transcode', 'alac'],
    ]);
    expect(plan[3].args).toContain('s32p');
    expect(plan[3].lossless).toBe(true);
  });

  it('never creates a lossless rendition for a lossy source', () => {
    const plan = planAudioRenditions(probe('mp3', 'mp3', 320_000));
    expect(plan.find((p) => p.profile === 'lossless')).toBeUndefined();
  });

  it('reuses a compatible low-bitrate original instead of re-encoding, and never upscales', () => {
    const plan = planAudioRenditions(probe('mp3', 'mp3', 128_000));
    expect(plan.find((p) => p.profile === 'standard')?.action).toBe('reuse_original');
    expect(plan.find((p) => p.profile === 'high')?.action).toBe('reuse_original');
    expect(plan.find((p) => p.profile === 'data_saver')).toMatchObject({ action: 'transcode', bitrateKbps: 96 });
  });

  it('caps transcode bitrate at the source bitrate for lossy sources', () => {
    const plan = planAudioRenditions(probe('ogg', 'vorbis', 192_000));
    expect(plan.find((p) => p.profile === 'high')).toMatchObject({ action: 'transcode', bitrateKbps: 192 });
  });

  it('reuses ALAC in MP4 as the lossless rendition', () => {
    const plan = planAudioRenditions(probe('mov,mp4,m4a,3gp,3g2,mj2', 'alac', 1_000_000));
    expect(plan.find((p) => p.profile === 'lossless')?.action).toBe('reuse_original');
  });
});

describe('profile selection', () => {
  it('falls back downwards first and never silently upgrades data saver to lossless', () => {
    expect(chooseProfile('lossless', ['data_saver', 'standard', 'high'])).toBe('high');
    expect(chooseProfile('standard', ['high', 'lossless'])).toBe('high');
    expect(chooseProfile('data_saver', ['standard', 'lossless'])).toBe('standard');
    expect(chooseProfile('high', ['high'])).toBe('high');
    expect(chooseProfile('high', [])).toBeNull();
  });
});

describe('video ladder', () => {
  it('never upscales', () => {
    expect(planVideoLadder(720).map((r) => r.height)).toEqual([360, 540, 720]);
    expect(planVideoLadder(2160).map((r) => r.height)).toEqual([360, 540, 720, 1080]);
    expect(planVideoLadder(241).map((r) => r.height)).toEqual([240]);
  });

  it('parses HLS master playlists', () => {
    const m = `#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="a",URI="audio_0/index.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,AUDIO="aud"\n360p/index.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1280x720\n720p/index.m3u8\n`;
    expect(parseMaster(m)).toEqual([
      { bandwidth: 900000, width: 640, height: 360, uri: '360p/index.m3u8' },
      { bandwidth: 3000000, width: 1280, height: 720, uri: '720p/index.m3u8' },
    ]);
  });
});

describe('metadata', () => {
  it('reads tags and lets overrides win', () => {
    const p: ProbeResult = {
      format: { format_name: 'flac', tags: { TITLE: 'Song', ARTIST: 'Band', ALBUM: 'Record', track: '3/12', DATE: '2021', GENRE: 'Indie; Rock', ITUNESADVISORY: '1' } },
      streams: [],
    };
    const m = extractTrackMetadata(p, 'file.flac');
    expect(m).toMatchObject({ title: 'Song', artistName: 'Band', albumTitle: 'Record', trackNumber: 3, releaseDate: '2021-01-01', genres: ['indie', 'rock'], explicit: true, albumType: 'album' });
    expect(extractTrackMetadata(p, 'x.flac', { title: 'Override', explicit: false })).toMatchObject({ title: 'Override', explicit: false });
  });

  it('falls back to "Artist - Title" file names', () => {
    const m = extractTrackMetadata({ format: { format_name: 'mp3' }, streams: [] }, '/tmp/Some Artist - Great Song.mp3');
    expect(m).toMatchObject({ artistName: 'Some Artist', title: 'Great Song', albumTitle: null, albumType: 'single' });
  });

  it('normalises helpers', () => {
    expect(normaliseDate('2019-07')).toBe('2019-07-01');
    expect(normaliseDate('garbage')).toBeNull();
    expect(splitList('Pop/Rock, pop')).toEqual(['pop', 'rock']);
    expect(toBcp47('eng')).toBe('en');
    expect(toBcp47('hrv')).toBe('hr');
    expect(toBcp47('xx1')).toBe('und');
    expect(safeFileName('../../etc/pa ss?wd.mp3')).toBe('pa_ss_wd.mp3');
    expect(safeFileName('.hidden')).toBe('hidden');
  });
});
