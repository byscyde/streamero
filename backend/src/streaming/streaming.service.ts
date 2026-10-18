import { Inject, Injectable } from '@nestjs/common';
import { notFound } from '../common/errors.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService } from '../db/db.service.js';
import type { StreamProfile } from '../media/profiles.js';
import { MediaSigner, type MediaGrant } from './media-signer.js';

const FALLBACK_ORDER: StreamProfile[] = ['lossless', 'high', 'standard', 'data_saver'];

/**
 * Picks the best available rendition for a requested profile. Requests for higher quality fall back
 * downwards; requests for lower quality fall back to the closest *lower-or-equal* bitrate first and
 * only then upwards, so "data saver" never silently streams lossless.
 */
export function chooseProfile(requested: StreamProfile, available: StreamProfile[]): StreamProfile | null {
  if (available.includes(requested)) return requested;
  const idx = FALLBACK_ORDER.indexOf(requested);
  const lower = FALLBACK_ORDER.slice(idx + 1).find((p) => available.includes(p));
  if (lower) return lower;
  return [...FALLBACK_ORDER.slice(0, idx)].reverse().find((p) => available.includes(p)) ?? null;
}

@Injectable()
export class StreamingService {
  readonly signer: MediaSigner;
  private readonly base: string;

  constructor(
    private readonly db: DbService,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {
    this.signer = new MediaSigner(config.MEDIA_SIGNING_SECRET);
    this.base = config.PUBLIC_BASE_URL.replace(/\/$/, '');
  }

  grantUrl(grant: Omit<MediaGrant, 'e'>, ttlSeconds = this.config.MEDIA_URL_TTL_SECONDS, suffix = '') {
    const e = Math.floor(Date.now() / 1000) + ttlSeconds;
    return { url: `${this.base}/v1/media/${this.signer.sign({ ...grant, e })}${suffix}`, expiresAt: new Date(e * 1000).toISOString() };
  }

  async trackStream(trackId: string, userId: string, requested: StreamProfile) {
    const rows = await this.db.query(
      `SELECT tr.profile, a.storage_key, a.mime_type, a.codec, a.bitrate, a.is_lossless, a.size_bytes, a.sample_rate, a.bit_depth,
              t.duration_ms, oa.codec AS src_codec, oa.is_lossless AS src_lossless, oa.sample_rate AS src_rate,
              oa.bit_depth AS src_depth, oa.bitrate AS src_bitrate, oa.container AS src_container
       FROM tracks t
       JOIN track_renditions tr ON tr.track_id = t.id
       JOIN media_assets a ON a.id = tr.asset_id
       LEFT JOIN media_assets oa ON oa.id = t.original_asset_id
       WHERE t.id = $1 AND t.status = 'ready'`,
      [trackId],
    );
    if (rows.length === 0) throw notFound('Playable track');
    const profile = chooseProfile(requested, rows.map((r) => r.profile))!;
    const r = rows.find((x) => x.profile === profile)!;
    const { url, expiresAt } = this.grantUrl({ k: r.storage_key, u: userId, t: r.mime_type });
    return {
      trackId,
      requestedProfile: requested,
      profile,
      url,
      expiresAt,
      mimeType: r.mime_type,
      durationMs: r.duration_ms,
      sizeBytes: Number(r.size_bytes),
      delivery: {
        codec: r.codec,
        bitrateKbps: r.bitrate ? Math.round(r.bitrate / 1000) : null,
        sampleRate: r.sample_rate,
        bitDepth: r.bit_depth,
        // Only true when the bytes delivered are actually lossless, never based on the source alone.
        lossless: r.is_lossless === true,
      },
      source: {
        codec: r.src_codec,
        container: r.src_container,
        lossless: r.src_lossless === true,
        sampleRate: r.src_rate,
        bitDepth: r.src_depth,
        bitrateKbps: r.src_bitrate ? Math.round(r.src_bitrate / 1000) : null,
      },
      availableProfiles: rows.map((x) => x.profile),
    };
  }

  async videoStream(videoId: string, userId: string) {
    const v = await this.db.one(
      `SELECT v.id, v.duration_ms, h.storage_key AS hls_key, h.metadata AS hls_meta,
              au.storage_key AS audio_key, au.mime_type AS audio_mime, au.bitrate AS audio_bitrate,
              pv.storage_key AS preview_key, pv.metadata AS preview_meta
       FROM videos v
       JOIN media_assets h ON h.id = v.hls_asset_id
       LEFT JOIN media_assets au ON au.id = v.audio_asset_id
       LEFT JOIN media_assets pv ON pv.id = v.preview_asset_id
       WHERE v.id = $1 AND v.status = 'ready'`,
      [videoId],
    );
    if (!v) throw notFound('Playable video');
    const [renditions, subtitles] = await Promise.all([
      this.db.query('SELECT height, width, bandwidth, playlist FROM video_renditions WHERE video_id = $1 ORDER BY height DESC', [videoId]),
      this.db.query(
        `SELECT s.id, s.language, s.label, s.kind, s.is_default, s.forced, a.storage_key
         FROM subtitle_tracks s JOIN media_assets a ON a.id = s.asset_id WHERE s.video_id = $1 ORDER BY s.is_default DESC, s.label`,
        [videoId],
      ),
    ]);
    const hls = this.grantUrl({ k: v.hls_key, u: userId, v: videoId });
    const token = hls.url.slice(hls.url.indexOf('/v1/media/') + '/v1/media/'.length);
    const hlsBase = `${this.base}/v1/media/${token}`;
    return {
      videoId,
      durationMs: v.duration_ms,
      hlsUrl: `${hlsBase}/master.m3u8`,
      expiresAt: hls.expiresAt,
      qualities: renditions.map((r) => ({ height: r.height, width: r.width, bandwidth: r.bandwidth, url: `${hlsBase}/${r.playlist}` })),
      audioTracks: (v.hls_meta?.audioTracks ?? []) as { language: string; name: string; isDefault: boolean }[],
      subtitles: subtitles.map((s) => ({
        id: s.id,
        language: s.language,
        label: s.label,
        kind: s.kind,
        isDefault: s.is_default,
        forced: s.forced,
        vttUrl: this.grantUrl({ k: s.storage_key, u: userId, t: 'text/vtt' }).url,
      })),
      audioOnly: v.audio_key
        ? {
            ...this.grantUrl({ k: v.audio_key, u: userId, t: v.audio_mime }),
            mimeType: v.audio_mime,
            bitrateKbps: v.audio_bitrate ? Math.round(v.audio_bitrate / 1000) : null,
          }
        : null,
      timelinePreview: v.preview_key
        ? {
            baseUrl: this.grantUrl({ k: v.preview_key, u: userId }).url,
            ...(v.preview_meta as { intervalSeconds: number; tileWidth: number; tileHeight: number; columns: number; rows: number; sheets: string[] }),
          }
        : null,
    };
  }

  /** Adds subtitle renditions to an HLS master playlist (subtitles can be attached after transcoding). */
  async rewriteMaster(master: string, videoId: string): Promise<string> {
    const subs = await this.db.query(
      'SELECT id, language, label, kind, is_default, forced FROM subtitle_tracks WHERE video_id = $1 ORDER BY is_default DESC, label',
      [videoId],
    );
    if (subs.length === 0) return master;
    const media = subs.map((s) => {
      const attrs = [
        'TYPE=SUBTITLES',
        'GROUP-ID="subs"',
        `NAME="${s.label.replace(/"/g, "'")}"`,
        `LANGUAGE="${s.language}"`,
        `DEFAULT=${s.is_default ? 'YES' : 'NO'}`,
        'AUTOSELECT=YES',
        `FORCED=${s.forced ? 'YES' : 'NO'}`,
      ];
      if (s.kind === 'captions') {
        attrs.push('CHARACTERISTICS="public.accessibility.transcribes-spoken-dialog,public.accessibility.describes-music-and-sound"');
      }
      attrs.push(`URI="subs/${s.id}.m3u8"`);
      return `#EXT-X-MEDIA:${attrs.join(',')}`;
    });
    const lines = master.split('\n');
    const out: string[] = [];
    let inserted = false;
    for (const line of lines) {
      if (!inserted && (line.startsWith('#EXT-X-STREAM-INF') || line.startsWith('#EXT-X-MEDIA'))) {
        out.push(...media);
        inserted = true;
      }
      out.push(line.startsWith('#EXT-X-STREAM-INF') && !line.includes('SUBTITLES=') ? `${line},SUBTITLES="subs"` : line);
    }
    return out.join('\n');
  }

  async subtitleForHls(videoId: string, subtitleId: string) {
    return this.db.one(
      `SELECT a.storage_key, v.duration_ms, h.metadata AS hls_meta FROM subtitle_tracks s
       JOIN media_assets a ON a.id = s.asset_id JOIN videos v ON v.id = s.video_id
       LEFT JOIN media_assets h ON h.id = v.hls_asset_id
       WHERE s.id = $1 AND s.video_id = $2`,
      [subtitleId, videoId],
    );
  }
}
