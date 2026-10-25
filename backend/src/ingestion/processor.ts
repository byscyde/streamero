import { createHash, randomUUID } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { Inject, Injectable, Logger } from '@nestjs/common';
import type pg from 'pg';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService } from '../db/db.service.js';
import { parseLrc } from '../lyrics/lrc.js';
import { AssetsService } from '../media/assets.service.js';
import { durationMs, Ffmpeg, type ProbeResult, type ProbeStream } from '../media/ffmpeg.js';
import { bitDepth, even, isLosslessSource, planAudioRenditions, planVideoLadder, primaryAudio, streamBitrateKbps } from '../media/profiles.js';
import { STORAGE } from '../storage/storage.module.js';
import { contentTypeForFile, type StorageDriver } from '../storage/storage.driver.js';
import { normaliseToWebVtt } from '../subtitles/subtitle-format.js';
import { extractTrackMetadata, languageName, safeFileName, toBcp47, type TrackOverrides } from './metadata.js';

export const MAX_MEDIA_DURATION_MS = 6 * 3600 * 1000;
const TEXT_SUBTITLE_CODECS = new Set(['subrip', 'mov_text', 'ass', 'ssa', 'webvtt', 'text']);

export class JobFailure extends Error {
  /** Permanent failures (invalid media) are not retried. */
  constructor(
    message: string,
    readonly permanent = true,
  ) {
    super(message);
  }
}

export interface JobContext {
  jobId: string;
  log(message: string): Promise<void>;
  progress(percent: number): Promise<void>;
}

export interface SourceRef {
  /** Object key in storage (uploads land in `incoming/`). */
  incomingKey?: string;
  /** Local file path already inside the job work directory (URL/path importers). */
  localPath?: string;
  filename: string;
}

export interface VideoOverrides {
  title?: string;
  description?: string;
  artistName?: string;
  trackId?: string;
  genres?: string[];
  explicit?: boolean;
  downloadable?: boolean;
}

export function isVideoProbe(p: ProbeResult) {
  return p.streams.some(
    (s) => s.codec_type === 'video' && !s.disposition?.attached_pic && !['mjpeg', 'png', 'bmp', 'gif'].includes(s.codec_name ?? ''),
  );
}

export async function sha256File(file: string): Promise<string> {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file)) hash.update(chunk as Buffer);
  return hash.digest('hex');
}

@Injectable()
export class MediaProcessor {
  private readonly logger = new Logger(MediaProcessor.name);
  readonly ffmpeg: Ffmpeg;

  constructor(
    private readonly db: DbService,
    private readonly assets: AssetsService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {
    this.ffmpeg = new Ffmpeg({
      ffmpegPath: config.FFMPEG_PATH,
      ffprobePath: config.FFPROBE_PATH,
      timeoutSeconds: config.FFMPEG_TIMEOUT_SECONDS,
      threads: config.FFMPEG_THREADS,
    });
  }

  workDir(jobId: string) {
    return path.resolve(this.config.WORK_DIR, 'jobs', jobId);
  }

  async withWorkDir<T>(jobId: string, fn: (dir: string) => Promise<T>): Promise<T> {
    const dir = this.workDir(jobId);
    await mkdir(dir, { recursive: true });
    try {
      return await fn(dir);
    } finally {
      await rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  }

  private async fetchSource(src: SourceRef, dir: string): Promise<string> {
    if (src.localPath) return src.localPath;
    if (!src.incomingKey) throw new JobFailure('Job has no source');
    const local = path.join(dir, `source${path.extname(safeFileName(src.filename)).toLowerCase() || '.bin'}`);
    await this.storage.downloadToFile(src.incomingKey, local);
    return local;
  }

  private async probeOrFail(file: string): Promise<ProbeResult> {
    try {
      return await this.ffmpeg.probe(file);
    } catch (err: any) {
      throw new JobFailure(`File is not a supported media file (${err.message})${err.stderrTail ? `: ${err.stderrTail.slice(0, 300)}` : ''}`);
    }
  }

  /** Decides audio vs. video from the actual streams, not from the file extension. */
  async ingestAuto(ctx: JobContext, src: SourceRef, opts: { overrides?: TrackOverrides & VideoOverrides; force?: boolean; provenance?: object }) {
    return this.withWorkDir(ctx.jobId, async (dir) => {
      const file = await this.fetchSource(src, dir);
      const probe = await this.probeOrFail(file);
      return isVideoProbe(probe)
        ? this.processVideo(ctx, file, probe, src, opts.overrides ?? {}, !!opts.force, opts.provenance)
        : this.processAudio(ctx, file, probe, src, opts.overrides ?? {}, !!opts.force, opts.provenance);
    });
  }

  // ------------------------------------------------------------------------------------------- audio

  async processAudio(ctx: JobContext, file: string, probe: ProbeResult, src: SourceRef, overrides: TrackOverrides, force: boolean, provenance?: object) {
    const audio = primaryAudio(probe);
    if (!audio) throw new JobFailure('File contains no audio stream');
    const duration = durationMs(probe);
    if (duration <= 0) throw new JobFailure('Could not determine media duration');
    if (duration > MAX_MEDIA_DURATION_MS) throw new JobFailure('Media longer than 6 hours is not accepted');
    await ctx.log(`Audio: ${audio.codec_name} ${audio.sample_rate ?? '?'} Hz, ${audio.channels ?? '?'} ch, ${Math.round(duration / 1000)} s, container ${probe.format.format_name}`);

    const checksum = await sha256File(file);
    if (!force) {
      const dup = await this.db.one(
        `SELECT t.id FROM tracks t JOIN media_assets a ON a.id = t.original_asset_id WHERE a.checksum_sha256 = $1 LIMIT 1`,
        [checksum],
      );
      if (dup) {
        await ctx.log(`Duplicate of existing track ${dup.id}; skipped (use force to import anyway)`);
        await this.cleanupIncoming(src);
        return { duplicate: true, trackId: dup.id };
      }
    }
    await ctx.progress(10);

    const meta = extractTrackMetadata(probe, src.filename, overrides);
    const ext = path.extname(safeFileName(src.filename)).toLowerCase() || '.bin';
    const originalId = randomUUID();
    const originalKey = `originals/audio/${originalId}${ext}`;
    const size = (await stat(file)).size;
    await this.storage.putFile(originalKey, file, contentTypeForFile(originalKey));
    await ctx.log(`Stored original (${(size / 1048576).toFixed(1)} MB, sha256 ${checksum.slice(0, 12)}…)`);

    const { trackId, albumId, artistId } = await this.db.tx(async (client) => {
      await this.insertAsset(client, {
        id: originalId,
        kind: 'original',
        key: originalKey,
        mime: contentTypeForFile(originalKey),
        size,
        checksum,
        probe,
        stream: audio,
        lossless: isLosslessSource(audio),
        metadata: { filename: safeFileName(src.filename), provenance: provenance ?? null },
      });
      const artistId = await this.upsertArtist(client, meta.artistName, meta.genres);
      const albumArtistId = meta.albumArtistName === meta.artistName ? artistId : await this.upsertArtist(client, meta.albumArtistName, meta.genres);
      const albumId = await this.upsertAlbum(client, albumArtistId, meta.albumTitle ?? meta.title, meta.albumTitle ? meta.albumType : 'single', meta);
      const track = await this.db.one(
        `INSERT INTO tracks (title, artist_id, album_id, disc_number, track_number, duration_ms, explicit, genres, moods, isrc, original_asset_id, status, downloadable)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'processing', $12) RETURNING id`,
        [meta.title, artistId, albumId, meta.discNumber, meta.trackNumber, duration, meta.explicit, meta.genres, meta.moods, meta.isrc, originalId, overrides.downloadable ?? true],
        client,
      );
      return { trackId: track.id as string, albumId, artistId };
    });
    await ctx.log(`Catalog: track ${trackId} "${meta.title}" by ${meta.artistName}`);
    await ctx.progress(20);

    try {
      await this.extractAlbumArtwork(ctx, file, probe, albumId, path.dirname(file));
      await ctx.progress(30);
      const renditions = await this.buildAudioRenditions(ctx, trackId, file, probe, originalId, path.dirname(file), 30, 95);
      if (meta.lyrics) await this.saveLyrics(trackId, meta.lyrics, overrides.lyricsSource ?? 'embedded', overrides.lyricsLicense ?? null);
      await this.db.query(`UPDATE tracks SET status = 'ready' WHERE id = $1`, [trackId]);
      await this.cleanupIncoming(src);
      await ctx.progress(100);
      return { trackId, albumId, artistId, renditions };
    } catch (err) {
      await this.db.query(`UPDATE tracks SET status = 'failed' WHERE id = $1`, [trackId]);
      throw err;
    }
  }

  async buildAudioRenditions(ctx: JobContext, trackId: string, file: string, probe: ProbeResult, originalId: string, dir: string, from: number, to: number) {
    const plan = planAudioRenditions(probe);
    const created: { profile: string; action: string; bitrateKbps: number | null; lossless: boolean }[] = [];
    const step = (to - from) / Math.max(1, plan.length);
    for (const [i, entry] of plan.entries()) {
      let assetId = originalId;
      if (entry.action === 'transcode') {
        const out = path.join(dir, `${entry.profile}.${entry.ext}`);
        await this.ffmpeg.exec([file], [...entry.args!, out], {
          durationMs: durationMs(probe),
          onProgress: (f) => void ctx.progress(Math.round(from + step * (i + f))).catch(() => undefined),
        });
        const outProbe = await this.ffmpeg.probe(out);
        const outAudio = primaryAudio(outProbe);
        assetId = randomUUID();
        const key = `renditions/audio/${trackId}/${entry.profile}.${entry.ext}`;
        await this.storage.putFile(key, out, 'audio/mp4');
        await this.db.tx((client) =>
          this.insertAsset(client, {
            id: assetId,
            kind: 'audio_rendition',
            key,
            mime: 'audio/mp4',
            size: Number(outProbe.format.size ?? 0),
            checksum: null,
            probe: outProbe,
            stream: outAudio,
            lossless: entry.lossless,
            profile: entry.profile,
          }),
        );
        await rm(out, { force: true });
      }
      await this.db.query(
        `INSERT INTO track_renditions (track_id, profile, asset_id) VALUES ($1, $2, $3)
         ON CONFLICT (track_id, profile) DO UPDATE SET asset_id = EXCLUDED.asset_id`,
        [trackId, entry.profile, assetId],
      );
      created.push({ profile: entry.profile, action: entry.action, bitrateKbps: entry.bitrateKbps, lossless: entry.lossless });
      await ctx.log(`Rendition ${entry.profile}: ${entry.action === 'reuse_original' ? 'original reused (already compatible)' : `${entry.codec}${entry.bitrateKbps ? ` ${entry.bitrateKbps} kbps` : ''}`}`);
      await ctx.progress(Math.round(from + step * (i + 1)));
    }
    return created;
  }

  private async extractAlbumArtwork(ctx: JobContext, file: string, probe: ProbeResult, albumId: string, dir: string) {
    const pic = probe.streams.find((s) => s.codec_type === 'video' && (s.disposition?.attached_pic || ['mjpeg', 'png'].includes(s.codec_name ?? '')));
    if (!pic) return;
    const album = await this.db.one('SELECT artwork_asset_id FROM albums WHERE id = $1', [albumId]);
    if (album?.artwork_asset_id) return;
    const assetId = await this.createImageAsset(file, dir, 'artwork', `0:${pic.index}`);
    await this.db.query('UPDATE albums SET artwork_asset_id = $2 WHERE id = $1 AND artwork_asset_id IS NULL', [albumId, assetId]);
    await ctx.log('Extracted embedded artwork');
  }

  /** Renders large (1000px) and small (300px) JPEG variants from an image or video frame. */
  async createImageAsset(input: string, dir: string, kind: 'artwork' | 'thumbnail', map?: string, seekSeconds?: number, square = true) {
    const id = randomUUID();
    const prefix = `${kind}/${id}/`;
    const variants = [
      ['large', 1000],
      ['small', 300],
    ] as const;
    let bytes = 0;
    let width = 0;
    let height = 0;
    for (const [name, px] of variants) {
      const out = path.join(dir, `${kind}-${name}.jpg`);
      const vf = square
        ? `scale=${px}:${px}:force_original_aspect_ratio=increase,crop=${px}:${px}`
        : `scale=${kind === 'thumbnail' && name === 'large' ? 1280 : px * 2}:-2`;
      await this.ffmpeg.exec(
        [seekSeconds !== undefined ? { path: input, pre: ['-ss', seekSeconds.toFixed(2)] } : input],
        [...(map ? ['-map', map] : []), '-frames:v', '1', '-vf', vf, '-q:v', '3', '-f', 'image2', '-c:v', 'mjpeg', out],
      );
      const info = await stat(out);
      bytes += info.size;
      if (name === 'large') {
        const p = await this.ffmpeg.probe(out, { trusted: true });
        width = p.streams[0]?.width ?? 0;
        height = p.streams[0]?.height ?? 0;
      }
      await this.storage.putFile(`${prefix}${name}.jpg`, out, 'image/jpeg');
    }
    await this.db.query(
      `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, width, height) VALUES ($1, $2, $3, 'image/jpeg', $4, $5, $6)`,
      [id, kind, prefix, bytes, width, height],
    );
    return id;
  }

  // ------------------------------------------------------------------------------------------- video

  async processVideo(ctx: JobContext, file: string, probe: ProbeResult, src: SourceRef, overrides: VideoOverrides & TrackOverrides, force: boolean, provenance?: object) {
    const video = probe.streams.find((s) => s.codec_type === 'video' && !s.disposition?.attached_pic)!;
    const audios = probe.streams.filter((s) => s.codec_type === 'audio');
    const duration = durationMs(probe);
    if (duration <= 0) throw new JobFailure('Could not determine media duration');
    if (duration > MAX_MEDIA_DURATION_MS) throw new JobFailure('Media longer than 6 hours is not accepted');
    if (!video.width || !video.height) throw new JobFailure('Video stream has no dimensions');
    await ctx.log(`Video: ${video.codec_name} ${video.width}x${video.height}, ${audios.length} audio stream(s), ${Math.round(duration / 1000)} s`);

    const checksum = await sha256File(file);
    if (!force) {
      const dup = await this.db.one(
        `SELECT v.id FROM videos v JOIN media_assets a ON a.id = v.original_asset_id WHERE a.checksum_sha256 = $1 LIMIT 1`,
        [checksum],
      );
      if (dup) {
        await ctx.log(`Duplicate of existing video ${dup.id}; skipped`);
        await this.cleanupIncoming(src);
        return { duplicate: true, videoId: dup.id };
      }
    }

    const meta = extractTrackMetadata(probe, src.filename, overrides);
    const ext = path.extname(safeFileName(src.filename)).toLowerCase() || '.bin';
    const originalId = randomUUID();
    const originalKey = `originals/video/${originalId}${ext}`;
    const size = (await stat(file)).size;
    await this.storage.putFile(originalKey, file, contentTypeForFile(originalKey));
    const videoId = await this.db.tx(async (client) => {
      await this.insertAsset(client, {
        id: originalId, kind: 'original', key: originalKey, mime: contentTypeForFile(originalKey), size, checksum, probe, stream: video,
        lossless: false, metadata: { filename: safeFileName(src.filename), provenance: provenance ?? null },
      });
      const artistName = overrides.artistName ?? (meta.artistName !== 'Unknown Artist' ? meta.artistName : undefined);
      const artistId = artistName ? await this.upsertArtist(client, artistName, meta.genres) : null;
      const v = await this.db.one(
        `INSERT INTO videos (title, description, artist_id, track_id, duration_ms, explicit, genres, original_asset_id, status, downloadable)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'processing', $9) RETURNING id`,
        [overrides.title ?? meta.title, overrides.description ?? null, artistId, overrides.trackId ?? null, duration, meta.explicit, meta.genres, originalId, overrides.downloadable ?? false],
        client,
      );
      return v.id as string;
    });
    await ctx.log(`Catalog: video ${videoId}`);
    await ctx.progress(5);
    const dir = path.dirname(file);
    try {
      const hls = await this.buildHls(ctx, videoId, file, probe, video, audios, dir, 5, 80);
      const thumbId = await this.createImageAsset(file, dir, 'thumbnail', `0:${video.index}`, Math.min(duration / 1000 / 10, 10), false);
      await ctx.log('Generated thumbnail');
      const previewId = await this.buildTimelinePreview(file, videoId, duration, dir).catch(async (err) => {
        await ctx.log(`Timeline preview skipped: ${err.message}`);
        return null;
      });
      await ctx.progress(88);
      let audioId: string | null = null;
      if (audios.length) {
        audioId = await this.buildAudioOnly(file, videoId, audios[0], duration, dir);
        await ctx.log('Prepared audio-only rendition');
      }
      await ctx.progress(93);
      await this.extractEmbeddedSubtitles(ctx, file, probe, videoId, dir);
      await this.db.query(
        `UPDATE videos SET hls_asset_id = $2, thumbnail_asset_id = $3, preview_asset_id = $4, audio_asset_id = $5, status = 'ready' WHERE id = $1`,
        [videoId, hls, thumbId, previewId, audioId],
      );
      await this.cleanupIncoming(src);
      await ctx.progress(100);
      return { videoId };
    } catch (err) {
      await this.db.query(`UPDATE videos SET status = 'failed' WHERE id = $1`, [videoId]);
      throw err;
    }
  }

  private async buildHls(ctx: JobContext, videoId: string, file: string, probe: ProbeResult, video: ProbeStream, audios: ProbeStream[], dir: string, from: number, to: number) {
    const ladder = planVideoLadder(video.height!);
    const out = path.join(dir, 'hls');
    await mkdir(out, { recursive: true });
    const args: string[] = [];
    const streamMap: string[] = [];
    ladder.forEach((r, i) => {
      args.push('-map', `0:${video.index}`);
      args.push(`-filter:v:${i}`, `scale=-2:${r.height}:flags=lanczos,format=yuv420p`);
      args.push(`-b:v:${i}`, `${r.videoKbps}k`, `-maxrate:v:${i}`, `${r.maxrateKbps}k`, `-bufsize:v:${i}`, `${r.videoKbps * 2}k`);
      streamMap.push(`v:${i},${audios.length ? 'agroup:aud,' : ''}name:${r.height}p`);
    });
    const audioTracks: { language: string; name: string; isDefault: boolean }[] = [];
    audios.forEach((a, j) => {
      args.push('-map', `0:${a.index}`);
      const lang = toBcp47(a.tags?.language);
      const name = (a.tags?.title ?? (lang !== 'und' ? languageName(lang) : `Audio ${j + 1}`)).replace(/[,:\s]+/g, '_');
      const isDefault = j === 0;
      audioTracks.push({ language: lang, name: name.replace(/_/g, ' '), isDefault });
      streamMap.push(`a:${j},agroup:aud,language:${lang},name:audio_${j}_${name.slice(0, 30)}${isDefault ? ',default:yes' : ''}`);
    });
    // Fixed GOP aligned with the segment duration keeps renditions switchable at every segment boundary.
    const fps = parseFps(video.avg_frame_rate) || 30;
    const gop = Math.round(fps * 2);
    args.push(
      '-c:v', 'libx264', '-preset', 'veryfast', '-profile:v', 'high', '-g', String(gop), '-keyint_min', String(gop), '-sc_threshold', '0',
      '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-ar', '48000',
      '-f', 'hls', '-hls_time', '6', '-hls_playlist_type', 'vod', '-hls_flags', 'independent_segments',
      '-hls_segment_type', 'mpegts', '-hls_segment_filename', path.join(out, '%v', 'seg_%05d.ts'),
      '-master_pl_name', 'master.m3u8', '-var_stream_map', streamMap.join(' '), path.join(out, '%v', 'index.m3u8'),
    );
    await ctx.log(`Transcoding HLS ladder: ${ladder.map((r) => `${r.height}p`).join(', ')}`);
    await this.ffmpeg.exec([file], args, {
      durationMs: durationMs(probe),
      onProgress: (f) => void ctx.progress(Math.round(from + (to - from) * f)).catch(() => undefined),
    });
    const master = await readFile(path.join(out, 'master.m3u8'), 'utf8');
    const variants = parseMaster(master);
    if (variants.length === 0) throw new JobFailure('HLS packaging produced no variants', false);
    // WebVTT subtitles need the MPEG-TS start PTS for X-TIMESTAMP-MAP alignment.
    const firstDir = variants[0].uri.split('/')[0];
    const firstSeg = (await readdir(path.join(out, firstDir))).find((f) => f.endsWith('.ts'));
    let mpegtsStart = 126000;
    if (firstSeg) {
      const sp = await this.ffmpeg.probe(path.join(out, firstDir, firstSeg)).catch(() => null);
      const st = Number(sp?.streams.find((s) => s.codec_type === 'video')?.['start_time' as keyof ProbeStream] ?? sp?.format['start_time' as keyof typeof sp.format] ?? NaN);
      if (Number.isFinite(st)) mpegtsStart = Math.round(st * 90000);
    }
    const prefix = `hls/${videoId}/`;
    const uploaded = await this.storage.putDirectory(prefix, out, contentTypeForFile);
    const assetId = randomUUID();
    await this.db.query(
      `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, codec, width, height, duration_ms, metadata)
       VALUES ($1, 'hls', $2, 'application/vnd.apple.mpegurl', $3, 'h264', $4, $5, $6, $7)`,
      [assetId, prefix, uploaded.bytes, video.width, video.height, durationMs(probe), JSON.stringify({ mpegtsStart, audioTracks, files: uploaded.files })],
    );
    for (const v of variants) {
      await this.db.query(
        `INSERT INTO video_renditions (video_id, height, width, bandwidth, playlist) VALUES ($1, $2, $3, $4, $5)
         ON CONFLICT (video_id, height) DO UPDATE SET width = EXCLUDED.width, bandwidth = EXCLUDED.bandwidth, playlist = EXCLUDED.playlist`,
        [videoId, v.height, v.width, v.bandwidth, v.uri],
      );
    }
    await ctx.log(`HLS packaged: ${uploaded.files} files, ${(uploaded.bytes / 1048576).toFixed(1)} MB`);
    return assetId;
  }

  private async buildTimelinePreview(file: string, videoId: string, duration: number, dir: string) {
    const seconds = duration / 1000;
    const interval = Math.max(2, Math.ceil(seconds / 100));
    const out = path.join(dir, 'preview');
    await mkdir(out, { recursive: true });
    const cols = 10;
    const rows = 10;
    await this.ffmpeg.exec(
      [file],
      ['-map', '0:v:0', '-vf', `fps=1/${interval},scale=160:90:force_original_aspect_ratio=decrease,pad=160:90:(ow-iw)/2:(oh-ih)/2,tile=${cols}x${rows}`,
        '-q:v', '5', '-f', 'image2', '-c:v', 'mjpeg', path.join(out, 'sprite_%03d.jpg')],
    );
    const sheets = (await readdir(out)).filter((f) => f.endsWith('.jpg')).sort();
    if (!sheets.length) return null;
    const prefix = `previews/${videoId}/`;
    const up = await this.storage.putDirectory(prefix, out, contentTypeForFile);
    const id = randomUUID();
    await this.db.query(
      `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, metadata) VALUES ($1, 'preview', $2, 'image/jpeg', $3, $4)`,
      [id, prefix, up.bytes, JSON.stringify({ intervalSeconds: interval, tileWidth: 160, tileHeight: 90, columns: cols, rows, sheets })],
    );
    return id;
  }

  private async buildAudioOnly(file: string, videoId: string, audio: ProbeStream, duration: number, dir: string) {
    const out = path.join(dir, 'audio-only.m4a');
    await this.ffmpeg.exec([file], ['-map', `0:${audio.index}`, '-vn', '-c:a', 'aac', '-b:a', '160k', '-ac', '2', '-movflags', '+faststart', '-f', 'mp4', out], { durationMs: duration });
    const p = await this.ffmpeg.probe(out);
    const id = randomUUID();
    const key = `audio-only/${videoId}/audio.m4a`;
    await this.storage.putFile(key, out, 'audio/mp4');
    await this.db.tx((client) =>
      this.insertAsset(client, { id, kind: 'audio_only', key, mime: 'audio/mp4', size: Number(p.format.size ?? 0), checksum: null, probe: p, stream: primaryAudio(p), lossless: false, profile: 'standard' }),
    );
    return id;
  }

  private async extractEmbeddedSubtitles(ctx: JobContext, file: string, probe: ProbeResult, videoId: string, dir: string) {
    const subs = probe.streams.filter((s) => s.codec_type === 'subtitle');
    for (const [k, s] of subs.entries()) {
      if (!TEXT_SUBTITLE_CODECS.has(s.codec_name ?? '')) {
        await ctx.log(`Subtitle stream ${s.index} (${s.codec_name}) is image-based and cannot be converted to WebVTT; skipped`);
        continue;
      }
      const out = path.join(dir, `embedded-${k}.vtt`);
      try {
        await this.ffmpeg.exec([file], ['-map', `0:${s.index}`, '-c:s', 'webvtt', '-f', 'webvtt', out]);
        const language = toBcp47(s.tags?.language);
        const kind = s.disposition?.hearing_impaired ? 'captions' : 'subtitles';
        await this.storeSubtitle(videoId, await readFile(out, 'utf8'), null, {
          language: language === 'und' ? 'und' : language,
          label: s.tags?.title ?? (language !== 'und' ? languageName(language) : `Subtitles ${k + 1}`),
          kind,
          isDefault: !!s.disposition?.default,
          forced: !!s.disposition?.forced,
        });
        await ctx.log(`Extracted embedded ${kind} (${language})`);
      } catch (err: any) {
        await ctx.log(`Embedded subtitle ${s.index} could not be converted: ${err.message}`);
      }
    }
  }

  // ------------------------------------------------------------------------------------------- subtitles

  async attachSubtitle(ctx: JobContext, input: { videoId: string; incomingKey: string; filename: string; language: string; label?: string; kind?: 'subtitles' | 'captions' | 'descriptions'; isDefault?: boolean; forced?: boolean; offsetMs?: number }) {
    const video = await this.db.one('SELECT id FROM videos WHERE id = $1', [input.videoId]);
    if (!video) throw new JobFailure('Video not found');
    return this.withWorkDir(ctx.jobId, async (dir) => {
      const local = path.join(dir, 'subtitle.src');
      await this.storage.downloadToFile(input.incomingKey, local);
      const raw = await readFile(local);
      if (raw.length > 5 * 1024 * 1024) throw new JobFailure('Subtitle file exceeds 5 MB');
      const text = decodeText(raw);
      const id = await this.storeSubtitle(input.videoId, text, { buffer: raw, filename: input.filename }, {
        language: input.language,
        label: input.label ?? languageName(input.language),
        kind: input.kind ?? 'subtitles',
        isDefault: !!input.isDefault,
        forced: !!input.forced,
        offsetMs: input.offsetMs ?? 0,
      });
      await this.storage.delete(input.incomingKey).catch(() => undefined);
      await ctx.log(`Subtitle ${id} attached (${input.language})`);
      await ctx.progress(100);
      return { subtitleId: id };
    });
  }

  /** Stores the preserved original and the normalised WebVTT, replacing an existing track of the same language/kind. */
  async storeSubtitle(
    videoId: string,
    text: string,
    original: { buffer: Buffer; filename: string } | null,
    o: { language: string; label: string; kind: 'subtitles' | 'captions' | 'descriptions'; isDefault: boolean; forced: boolean; offsetMs?: number },
  ) {
    let normalised;
    try {
      normalised = normaliseToWebVtt(text, o.offsetMs ?? 0);
    } catch (err: any) {
      throw new JobFailure(`Subtitle could not be parsed: ${err.message}`);
    }
    const subId = randomUUID();
    const vttId = randomUUID();
    const vttKey = `subtitles/${videoId}/${subId}.vtt`;
    await this.storage.putBuffer(vttKey, Buffer.from(normalised.vtt, 'utf8'), 'text/vtt');
    let originalId: string | null = null;
    let originalKey: string | null = null;
    if (original) {
      originalId = randomUUID();
      const ext = path.extname(safeFileName(original.filename)).toLowerCase() || `.${normalised.sourceFormat}`;
      originalKey = `subtitles/${videoId}/${subId}.original${ext}`;
      await this.storage.putBuffer(originalKey, original.buffer, contentTypeForFile(originalKey));
    }
    const replaced = await this.db.tx(async (client) => {
      await this.db.query(
        `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, metadata) VALUES ($1, 'subtitle', $2, 'text/vtt', $3, $4)`,
        [vttId, vttKey, Buffer.byteLength(normalised.vtt), JSON.stringify({ cues: normalised.cueCount, sourceFormat: normalised.sourceFormat })],
        client,
      );
      if (originalId) {
        await this.db.query(
          `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, profile) VALUES ($1, 'subtitle', $2, $3, $4, 'original')`,
          [originalId, originalKey, contentTypeForFile(originalKey!), original!.buffer.length],
          client,
        );
      }
      if (o.isDefault) await this.db.query('UPDATE subtitle_tracks SET is_default = false WHERE video_id = $1', [videoId], client);
      const prev = await this.db.one(
        'SELECT id, asset_id, original_asset_id FROM subtitle_tracks WHERE video_id = $1 AND language = $2 AND kind = $3',
        [videoId, o.language, o.kind],
        client,
      );
      if (prev) await this.db.query('DELETE FROM subtitle_tracks WHERE id = $1', [prev.id], client);
      await this.db.query(
        `INSERT INTO subtitle_tracks (id, video_id, language, label, kind, is_default, forced, asset_id, original_asset_id)
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)`,
        [subId, videoId, o.language, o.label.slice(0, 100), o.kind, o.isDefault, o.forced, vttId, originalId],
        client,
      );
      return prev;
    });
    if (replaced) await this.assets.deleteIfUnreferenced([replaced.asset_id, replaced.original_asset_id]);
    return subId;
  }

  // ------------------------------------------------------------------------------------------- artwork

  async attachArtwork(ctx: JobContext, input: { incomingKey: string; filename: string; targetType: 'album' | 'artist' | 'playlist'; targetId: string }) {
    const table = { album: 'albums', artist: 'artists', playlist: 'playlists' }[input.targetType];
    if (!table) throw new JobFailure('Invalid artwork target');
    const target = await this.db.one(`SELECT id, artwork_asset_id FROM ${table} WHERE id = $1`, [input.targetId]);
    if (!target) throw new JobFailure(`${input.targetType} not found`);
    return this.withWorkDir(ctx.jobId, async (dir) => {
      // No extension: FFmpeg must detect the image type from its content, not from the client-chosen name.
      const file = path.join(dir, 'artwork-upload');
      await this.storage.downloadToFile(input.incomingKey, file);
      const probe = await this.probeOrFail(file);
      const img = probe.streams.find((s) => s.codec_type === 'video');
      if (!img || !['mjpeg', 'png', 'webp'].includes(img.codec_name ?? '')) throw new JobFailure('Artwork must be a JPEG, PNG or WebP image');
      if ((img.width ?? 0) < 300 || (img.height ?? 0) < 300) throw new JobFailure('Artwork must be at least 300x300 pixels');
      const assetId = await this.replaceArtwork(table, input.targetId, target.artwork_asset_id, file, dir);
      await this.storage.delete(input.incomingKey).catch(() => undefined);
      await ctx.progress(100);
      return { assetId, targetType: input.targetType, targetId: input.targetId };
    });
  }

  /** Renders the image variants, points the entity at the new asset and removes the old one if unused. */
  private async replaceArtwork(table: string, targetId: string, oldAssetId: string | null, file: string, dir: string) {
    const assetId = await this.createImageAsset(file, dir, 'artwork');
    await this.db.query(`UPDATE ${table} SET artwork_asset_id = $2 WHERE id = $1`, [targetId, assetId]);
    await this.assets.deleteIfUnreferenced([oldAssetId]);
    return assetId;
  }

  /**
   * Stores artwork from bytes fetched server-side (e.g. Cover Art Archive), exactly like an uploaded
   * artwork: content-sniffed, probed, re-encoded into the large/small JPEG variants.
   */
  async storeArtworkBuffer(buf: Buffer, targetType: 'album' | 'artist' | 'playlist', targetId: string): Promise<string> {
    const table = { album: 'albums', artist: 'artists', playlist: 'playlists' }[targetType];
    const target = await this.db.one(`SELECT id, artwork_asset_id FROM ${table} WHERE id = $1`, [targetId]);
    if (!target) throw new JobFailure(`${targetType} not found`);
    return this.withWorkDir(`artwork-${randomUUID()}`, async (dir) => {
      const file = path.join(dir, 'artwork-download');
      await writeFile(file, buf);
      const probe = await this.probeOrFail(file);
      const img = probe.streams.find((s) => s.codec_type === 'video');
      if (!img || !['mjpeg', 'png', 'webp'].includes(img.codec_name ?? '')) throw new JobFailure('Artwork must be a JPEG, PNG or WebP image');
      if ((img.width ?? 0) < 100 || (img.height ?? 0) < 100) throw new JobFailure('Artwork is too small');
      return this.replaceArtwork(table, targetId, target.artwork_asset_id, file, dir);
    });
  }

  // ------------------------------------------------------------------------------------------- reprocess

  async reprocessTrack(ctx: JobContext, trackId: string) {
    const t = await this.db.one(
      `SELECT t.id, a.id AS asset_id, a.storage_key FROM tracks t JOIN media_assets a ON a.id = t.original_asset_id WHERE t.id = $1`,
      [trackId],
    );
    if (!t) throw new JobFailure('Track or original media not found');
    return this.withWorkDir(ctx.jobId, async (dir) => {
      const file = path.join(dir, `source${path.extname(t.storage_key)}`);
      await this.storage.downloadToFile(t.storage_key, file);
      const probe = await this.probeOrFail(file);
      const old = await this.db.query('SELECT asset_id FROM track_renditions WHERE track_id = $1', [trackId]);
      await this.db.query('DELETE FROM track_renditions WHERE track_id = $1', [trackId]);
      const renditions = await this.buildAudioRenditions(ctx, trackId, file, probe, t.asset_id, dir, 10, 95);
      await this.db.query(`UPDATE tracks SET status = 'ready' WHERE id = $1`, [trackId]);
      await this.assets.deleteIfUnreferenced(old.map((o) => o.asset_id));
      await ctx.progress(100);
      return { trackId, renditions };
    });
  }

  async reprocessVideo(ctx: JobContext, videoId: string) {
    const v = await this.db.one(
      `SELECT v.*, a.storage_key FROM videos v JOIN media_assets a ON a.id = v.original_asset_id WHERE v.id = $1`,
      [videoId],
    );
    if (!v) throw new JobFailure('Video or original media not found');
    return this.withWorkDir(ctx.jobId, async (dir) => {
      const file = path.join(dir, `source${path.extname(v.storage_key)}`);
      await this.storage.downloadToFile(v.storage_key, file);
      const probe = await this.probeOrFail(file);
      const video = probe.streams.find((s) => s.codec_type === 'video' && !s.disposition?.attached_pic);
      if (!video) throw new JobFailure('Original has no video stream');
      const audios = probe.streams.filter((s) => s.codec_type === 'audio');
      const oldAssets = [v.hls_asset_id, v.thumbnail_asset_id, v.preview_asset_id, v.audio_asset_id];
      await this.db.query(`UPDATE videos SET status = 'processing', hls_asset_id = NULL, thumbnail_asset_id = NULL, preview_asset_id = NULL, audio_asset_id = NULL WHERE id = $1`, [videoId]);
      await this.db.query('DELETE FROM video_renditions WHERE video_id = $1', [videoId]);
      await this.assets.deleteIfUnreferenced(oldAssets);
      const hls = await this.buildHls(ctx, videoId, file, probe, video, audios, dir, 5, 85);
      const thumb = await this.createImageAsset(file, dir, 'thumbnail', `0:${video.index}`, Math.min(durationMs(probe) / 10000, 10), false);
      const preview = await this.buildTimelinePreview(file, videoId, durationMs(probe), dir).catch(() => null);
      const audio = audios.length ? await this.buildAudioOnly(file, videoId, audios[0], durationMs(probe), dir) : null;
      await this.db.query(
        `UPDATE videos SET hls_asset_id = $2, thumbnail_asset_id = $3, preview_asset_id = $4, audio_asset_id = $5, status = 'ready' WHERE id = $1`,
        [videoId, hls, thumb, preview, audio],
      );
      await ctx.progress(100);
      return { videoId };
    });
  }

  // ------------------------------------------------------------------------------------------- helpers

  async saveLyrics(trackId: string, content: string, source: string | null, license: string | null) {
    const parsed = parseLrc(content);
    await this.db.query(
      `INSERT INTO lyrics (track_id, kind, content, language, source, license_note) VALUES ($1, $2, $3, $4, $5, $6)
       ON CONFLICT (track_id) DO UPDATE SET kind = EXCLUDED.kind, content = EXCLUDED.content, language = EXCLUDED.language,
         source = EXCLUDED.source, license_note = EXCLUDED.license_note, updated_at = now()`,
      [trackId, parsed.synced ? 'synced' : 'plain', content, parsed.metadata.la ?? null, source, license],
    );
  }

  private async upsertArtist(client: pg.PoolClient, name: string, genres: string[]) {
    const row = await this.db.one(
      `INSERT INTO artists (name, genres) VALUES ($1, $2)
       ON CONFLICT ((lower(name))) DO UPDATE SET genres = CASE WHEN artists.genres = '{}' THEN EXCLUDED.genres ELSE artists.genres END
       RETURNING id`,
      [name, genres],
      client,
    );
    return row.id as string;
  }

  private async upsertAlbum(client: pg.PoolClient, artistId: string, title: string, type: string, meta: { releaseDate: string | null; genres: string[]; explicit: boolean; label: string | null }) {
    const row = await this.db.one(
      `INSERT INTO albums (title, artist_id, album_type, release_date, genres, explicit, label) VALUES ($1, $2, $3, $4, $5, $6, $7)
       ON CONFLICT (artist_id, (lower(title))) DO UPDATE SET
         release_date = coalesce(albums.release_date, EXCLUDED.release_date),
         genres = CASE WHEN albums.genres = '{}' THEN EXCLUDED.genres ELSE albums.genres END,
         explicit = albums.explicit OR EXCLUDED.explicit,
         label = coalesce(albums.label, EXCLUDED.label)
       RETURNING id`,
      [title, artistId, type, meta.releaseDate, meta.genres, meta.explicit, meta.label],
      client,
    );
    return row.id as string;
  }

  private async insertAsset(
    client: pg.PoolClient,
    a: { id: string; kind: string; key: string; mime: string; size: number; checksum: string | null; probe: ProbeResult; stream?: ProbeStream; lossless: boolean; profile?: string; metadata?: object },
  ) {
    const s = a.stream;
    await this.db.query(
      `INSERT INTO media_assets (id, kind, storage_key, mime_type, size_bytes, checksum_sha256, container, codec, bitrate, sample_rate, bit_depth, channels, duration_ms, width, height, is_lossless, profile, metadata)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18)`,
      [
        a.id, a.kind, a.key, a.mime, a.size, a.checksum, a.probe.format.format_name, s?.codec_name ?? null,
        s?.codec_type === 'audio' ? (streamBitrateKbps(a.probe, s) ?? 0) * 1000 || null : Number(a.probe.format.bit_rate ?? 0) || null,
        s?.sample_rate ? Number(s.sample_rate) : null, s?.codec_type === 'audio' && a.lossless ? bitDepth(s) : null, s?.channels ?? null,
        durationMs(a.probe), s?.width ?? null, s?.height ?? null, a.lossless, a.profile ?? null, JSON.stringify(a.metadata ?? {}),
      ],
      client,
    );
  }

  private async cleanupIncoming(src: SourceRef) {
    if (src.incomingKey) await this.storage.delete(src.incomingKey).catch((err) => this.logger.warn({ err }, 'Could not delete incoming upload'));
  }
}

function parseFps(v?: string) {
  if (!v) return 0;
  const [n, d] = v.split('/').map(Number);
  return d ? n / d : n;
}

/** Parses variant streams from an HLS master playlist. */
export function parseMaster(master: string) {
  const lines = master.split('\n').map((l) => l.trim());
  const out: { bandwidth: number; width: number; height: number; uri: string }[] = [];
  for (let i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
    const attrs = lines[i];
    const bw = Number(attrs.match(/BANDWIDTH=(\d+)/)?.[1] ?? 0);
    const res = attrs.match(/RESOLUTION=(\d+)x(\d+)/);
    const uri = lines.slice(i + 1).find((l) => l && !l.startsWith('#'));
    if (uri && res) out.push({ bandwidth: bw, width: Number(res[1]), height: even(Number(res[2])), uri });
  }
  return out;
}

/** Subtitle files in the wild are UTF-8, UTF-16 or Windows-1252; never fail on encoding alone. */
export function decodeText(buf: Buffer): string {
  if (buf[0] === 0xff && buf[1] === 0xfe) return new TextDecoder('utf-16le').decode(buf.subarray(2));
  if (buf[0] === 0xfe && buf[1] === 0xff) return new TextDecoder('utf-16be').decode(buf.subarray(2));
  try {
    return new TextDecoder('utf-8', { fatal: true }).decode(buf);
  } catch {
    return new TextDecoder('windows-1252').decode(buf);
  }
}
