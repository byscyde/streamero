import { HttpStatus, Injectable } from '@nestjs/common';
import { AppError, notFound } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { chooseProfile, StreamingService } from '../streaming/streaming.service.js';
import type { StreamProfile } from '../media/profiles.js';

/** How long an offline copy stays playable without the device checking in. */
export const OFFLINE_LICENSE_DAYS = 30;
const MAX_ACTIVE_DOWNLOADS = 10_000;

@Injectable()
export class DownloadsService {
  constructor(
    private readonly db: DbService,
    private readonly streaming: StreamingService,
  ) {}

  /**
   * Issues a download grant after checking entitlement server-side (item exists, is ready and is
   * downloadable; account active). The client receives a short-lived signed URL, never storage credentials.
   */
  async requestTrack(userId: string, trackId: string, requested: StreamProfile) {
    const rows = await this.db.query(
      `SELECT tr.profile, a.id AS asset_id, a.storage_key, a.mime_type, a.size_bytes, a.checksum_sha256, a.is_lossless, a.codec, a.bitrate, t.downloadable
       FROM tracks t JOIN track_renditions tr ON tr.track_id = t.id JOIN media_assets a ON a.id = tr.asset_id
       WHERE t.id = $1 AND t.status = 'ready'`,
      [trackId],
    );
    if (!rows.length) throw notFound('Track');
    if (!rows[0].downloadable) throw new AppError(HttpStatus.FORBIDDEN, 'not_downloadable', 'This track is not available for offline use');
    await this.assertQuota(userId);
    const profile = chooseProfile(requested, rows.map((r) => r.profile))!;
    const r = rows.find((x) => x.profile === profile)!;
    const grant = await this.db.one(
      `INSERT INTO download_grants (user_id, track_id, profile, asset_id, expires_at)
       VALUES ($1, $2, $3, $4, now() + make_interval(days => $5)) RETURNING id, expires_at`,
      [userId, trackId, profile, r.asset_id, OFFLINE_LICENSE_DAYS],
    );
    const url = this.streaming.grantUrl({ k: r.storage_key, u: userId, t: r.mime_type }, 3600);
    return {
      grantId: grant.id,
      trackId,
      profile,
      url: url.url,
      urlExpiresAt: url.expiresAt,
      licenseExpiresAt: grant.expires_at,
      mimeType: r.mime_type,
      sizeBytes: Number(r.size_bytes),
      checksumSha256: r.checksum_sha256,
      lossless: r.is_lossless === true,
      codec: r.codec,
    };
  }

  /** Video downloads use AVAssetDownloadURLSession against the HLS stream; the grant gates the license. */
  async requestVideo(userId: string, videoId: string) {
    const v = await this.db.one(`SELECT id, downloadable, hls_asset_id FROM videos WHERE id = $1 AND status = 'ready'`, [videoId]);
    if (!v) throw notFound('Video');
    if (!v.downloadable) throw new AppError(HttpStatus.FORBIDDEN, 'not_downloadable', 'This video is not available for offline use');
    await this.assertQuota(userId);
    const grant = await this.db.one(
      `INSERT INTO download_grants (user_id, video_id, profile, asset_id, expires_at)
       VALUES ($1, $2, 'hls', $3, now() + make_interval(days => $4)) RETURNING id, expires_at`,
      [userId, videoId, v.hls_asset_id, OFFLINE_LICENSE_DAYS],
    );
    const stream = await this.streaming.videoStream(videoId, userId);
    return { grantId: grant.id, videoId, licenseExpiresAt: grant.expires_at, hlsUrl: stream.hlsUrl, subtitles: stream.subtitles };
  }

  private async assertQuota(userId: string) {
    const n = await this.db.one(
      'SELECT count(*)::int AS n FROM download_grants WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now()',
      [userId],
    );
    if (n.n >= MAX_ACTIVE_DOWNLOADS) throw new AppError(HttpStatus.FORBIDDEN, 'download_limit', 'Offline download limit reached');
  }

  async list(userId: string) {
    const rows = await this.db.query(
      `SELECT id, track_id, video_id, profile, expires_at, created_at FROM download_grants
       WHERE user_id = $1 AND revoked_at IS NULL AND expires_at > now() ORDER BY created_at DESC`,
      [userId],
    );
    return { items: rows.map((r) => ({ grantId: r.id, trackId: r.track_id, videoId: r.video_id, profile: r.profile, licenseExpiresAt: r.expires_at })) };
  }

  /**
   * Devices call this when online. Valid grants are renewed (sliding expiry); anything revoked, expired,
   * removed from the catalog or no longer downloadable is reported so the device deletes the file.
   */
  async validate(userId: string, grantIds: string[]) {
    const rows = await this.db.query(
      `UPDATE download_grants g SET expires_at = now() + make_interval(days => $3)
       FROM download_grants g2
       LEFT JOIN tracks t ON t.id = g2.track_id LEFT JOIN videos v ON v.id = g2.video_id
       WHERE g.id = g2.id AND g.user_id = $1 AND g.id = ANY($2::uuid[]) AND g.revoked_at IS NULL AND g.expires_at > now()
         AND (t.id IS NULL OR (t.status = 'ready' AND t.downloadable))
         AND (v.id IS NULL OR (v.status = 'ready' AND v.downloadable))
         AND (g.track_id IS NULL OR t.id IS NOT NULL) AND (g.video_id IS NULL OR v.id IS NOT NULL)
       RETURNING g.id, g.expires_at`,
      [userId, grantIds, OFFLINE_LICENSE_DAYS],
    );
    const valid = new Map(rows.map((r) => [r.id, r.expires_at]));
    return {
      valid: [...valid.entries()].map(([grantId, licenseExpiresAt]) => ({ grantId, licenseExpiresAt })),
      revoked: grantIds.filter((id) => !valid.has(id)),
    };
  }

  async revoke(userId: string, grantId: string) {
    await this.db.query('UPDATE download_grants SET revoked_at = now() WHERE id = $1 AND user_id = $2', [grantId, userId]);
  }
}
