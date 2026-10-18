import type { ProbeResult, ProbeStream } from './ffmpeg.js';

export type StreamProfile = 'data_saver' | 'standard' | 'high' | 'lossless';
export const STREAM_PROFILES: StreamProfile[] = ['data_saver', 'standard', 'high', 'lossless'];

/** Target AAC bitrates (kbps) for lossy delivery profiles. */
export const AAC_BITRATE: Record<Exclude<StreamProfile, 'lossless'>, number> = {
  data_saver: 96,
  standard: 160,
  high: 256,
};

const LOSSLESS_CODECS = new Set(['flac', 'alac', 'wavpack', 'ape', 'tta', 'mlp', 'truehd']);
const isPcm = (codec?: string) => !!codec && codec.startsWith('pcm_');

export function primaryAudio(probe: ProbeResult): ProbeStream | undefined {
  return probe.streams.find((s) => s.codec_type === 'audio' && s.disposition?.default) ?? probe.streams.find((s) => s.codec_type === 'audio');
}

export function isLosslessSource(stream?: ProbeStream): boolean {
  return !!stream && (LOSSLESS_CODECS.has(stream.codec_name ?? '') || isPcm(stream.codec_name));
}

export function bitDepth(stream?: ProbeStream): number | null {
  const raw = Number(stream?.bits_per_raw_sample ?? 0) || Number(stream?.bits_per_sample ?? 0);
  if (raw) return raw;
  if (stream?.sample_fmt?.startsWith('s16')) return 16;
  if (stream?.sample_fmt?.startsWith('s32')) return 24; // FLAC/ALAC decoders expose 24-bit audio as s32
  return null;
}

export function streamBitrateKbps(probe: ProbeResult, stream?: ProbeStream): number | null {
  const bps = Number(stream?.bit_rate ?? probe.format.bit_rate ?? 0);
  return bps > 0 ? Math.round(bps / 1000) : null;
}

/**
 * Whether the original file can be delivered to AVPlayer unchanged for a lossy profile:
 * AAC/MP3 in a container AVFoundation plays natively, and no higher bitrate than the profile allows
 * (+10% tolerance for VBR estimates). This avoids pointless lossy-to-lossy re-encoding.
 */
export function canReuseOriginalForLossy(probe: ProbeResult, profile: Exclude<StreamProfile, 'lossless'>): boolean {
  const a = primaryAudio(probe);
  if (!a) return false;
  const fmt = probe.format.format_name;
  const nativeContainer = fmt.includes('mp4') || fmt.includes('m4a') || fmt === 'mp3' || fmt === 'aac';
  const nativeCodec = a.codec_name === 'aac' || a.codec_name === 'mp3';
  const kbps = streamBitrateKbps(probe, a);
  return nativeContainer && nativeCodec && kbps !== null && kbps <= AAC_BITRATE[profile] * 1.1;
}

export function canReuseOriginalForLossless(probe: ProbeResult): boolean {
  const a = primaryAudio(probe);
  const fmt = probe.format.format_name;
  return a?.codec_name === 'alac' && (fmt.includes('mp4') || fmt.includes('m4a'));
}

export interface AudioPlanEntry {
  profile: StreamProfile;
  action: 'reuse_original' | 'transcode';
  /** ffmpeg output args when transcoding. */
  args?: string[];
  ext: 'm4a';
  codec: 'aac' | 'alac';
  bitrateKbps: number | null;
  lossless: boolean;
}

/**
 * Plans the delivery renditions for an audio source.
 * - Lossy profiles never exceed the source quality: a 128 kbps MP3 is not "upgraded" to a 256 kbps AAC.
 * - The lossless profile exists only when the source itself is lossless (FLAC/WAV/ALAC/...), and is
 *   delivered as ALAC, which AVPlayer decodes natively. Lossy sources never get a lossless rendition.
 */
export function planAudioRenditions(probe: ProbeResult): AudioPlanEntry[] {
  const a = primaryAudio(probe);
  if (!a) return [];
  const sourceKbps = streamBitrateKbps(probe, a);
  const lossless = isLosslessSource(a);
  const plan: AudioPlanEntry[] = [];
  for (const profile of ['data_saver', 'standard', 'high'] as const) {
    let target = AAC_BITRATE[profile];
    if (!lossless && sourceKbps) target = Math.min(target, Math.max(64, Math.round(sourceKbps / 16) * 16));
    if (canReuseOriginalForLossy(probe, profile)) {
      plan.push({ profile, action: 'reuse_original', ext: 'm4a', codec: 'aac', bitrateKbps: sourceKbps, lossless: false });
      continue;
    }
    plan.push({
      profile,
      action: 'transcode',
      ext: 'm4a',
      codec: 'aac',
      bitrateKbps: target,
      lossless: false,
      args: ['-map', `0:${a.index}`, '-vn', '-map_metadata', '-1', '-c:a', 'aac', '-b:a', `${target}k`, '-ac', String(Math.min(a.channels ?? 2, 2)), '-movflags', '+faststart', '-f', 'mp4'],
    });
  }
  if (lossless) {
    const depth = bitDepth(a);
    plan.push({
      profile: 'lossless',
      action: canReuseOriginalForLossless(probe) ? 'reuse_original' : 'transcode',
      ext: 'm4a',
      codec: 'alac',
      bitrateKbps: null,
      lossless: true,
      args: [
        '-map', `0:${a.index}`, '-vn', '-map_metadata', '-1', '-c:a', 'alac',
        ...(depth && depth > 16 ? ['-sample_fmt', 's32p'] : ['-sample_fmt', 's16p']),
        '-movflags', '+faststart', '-f', 'mp4',
      ],
    });
  }
  return plan;
}

/** HLS video ladder; never upscales beyond the source resolution. */
export const VIDEO_LADDER = [
  { height: 360, videoKbps: 800, maxrateKbps: 856 },
  { height: 540, videoKbps: 1600, maxrateKbps: 1712 },
  { height: 720, videoKbps: 2800, maxrateKbps: 2996 },
  { height: 1080, videoKbps: 5000, maxrateKbps: 5350 },
] as const;

export function planVideoLadder(sourceHeight: number) {
  const rungs = VIDEO_LADDER.filter((r) => r.height <= sourceHeight);
  if (rungs.length === 0) return [{ ...VIDEO_LADDER[0], height: even(sourceHeight) }];
  return rungs;
}

export const even = (n: number) => Math.max(2, Math.floor(n / 2) * 2);
