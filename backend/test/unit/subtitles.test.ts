import { describe, expect, it } from 'vitest';
import { formatVttTimestamp, normaliseToWebVtt, parseSubtitles, parseTimestamp, withTimestampMap } from '../../src/subtitles/subtitle-format.js';
import { decodeText } from '../../src/ingestion/processor.js';

const SRT = `﻿1\r\n00:00:01,000 --> 00:00:03,500\r\nHello <font color="red">world</font> & friends\r\n\r\n2\r\n00:00:04,000 --> 00:00:06,000\r\n<i>Second</i> line\r\nwraps\r\n\r\n3\r\nbroken --> nope\r\nskip me\r\n\r\n4\r\n00:00:10,000 --> 00:00:09,000\r\nnegative duration skipped\r\n`;

describe('subtitles', () => {
  it('parses timestamps in SRT and VTT forms', () => {
    expect(parseTimestamp('00:00:01,250')).toBe(1250);
    expect(parseTimestamp('01:02.5')).toBe(62500);
    expect(parseTimestamp('1:00:00.000')).toBe(3_600_000);
    expect(formatVttTimestamp(3_723_004)).toBe('01:02:03.004');
  });

  it('converts SRT to WebVTT, dropping malformed cues and unsupported markup', () => {
    const { vtt, cueCount, sourceFormat } = normaliseToWebVtt(SRT);
    expect(sourceFormat).toBe('srt');
    expect(cueCount).toBe(2);
    expect(vtt.startsWith('WEBVTT\n')).toBe(true);
    expect(vtt).toContain('00:00:01.000 --> 00:00:03.500');
    expect(vtt).toContain('Hello world &amp; friends');
    expect(vtt).toContain('<i>Second</i> line\nwraps');
    expect(vtt).not.toContain('font');
  });

  it('applies a synchronisation offset', () => {
    const { vtt } = normaliseToWebVtt(SRT, 500);
    expect(vtt).toContain('00:00:01.500 --> 00:00:04.000');
  });

  it('keeps WebVTT cue settings', () => {
    const { cues, format } = parseSubtitles('WEBVTT\n\n00:01.000 --> 00:02.000 line:0 align:start\nTop\n');
    expect(format).toBe('vtt');
    expect(cues[0]).toMatchObject({ startMs: 1000, endMs: 2000, settings: 'line:0 align:start', text: 'Top' });
  });

  it('rejects files without cues', () => {
    expect(() => normaliseToWebVtt('just some text')).toThrow(/No valid subtitle cues/);
  });

  it('adds the HLS timestamp map header', () => {
    expect(withTimestampMap('WEBVTT\n\n1\n', 126000)).toBe('WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n1\n');
  });

  it('decodes UTF-16 and Windows-1252 subtitle files', () => {
    expect(decodeText(Buffer.from([0xff, 0xfe, 0x41, 0x00, 0x42, 0x00]))).toBe('AB');
    expect(decodeText(Buffer.from([0x63, 0x61, 0x66, 0xe9]))).toBe('café');
    expect(decodeText(Buffer.from('čćž', 'utf8'))).toBe('čćž');
  });
});
