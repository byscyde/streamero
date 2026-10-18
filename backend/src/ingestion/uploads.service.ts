import path from 'node:path';
import { Inject, Injectable } from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { AppError, badRequest, conflict, notFound } from '../common/errors.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService } from '../db/db.service.js';
import { STORAGE } from '../storage/storage.module.js';
import { contentTypeForFile, type StorageDriver } from '../storage/storage.driver.js';
import { MEDIA_EXTENSIONS } from './importers.js';
import { JobsService } from './jobs.service.js';
import { safeFileName } from './metadata.js';

export const CHUNK_BYTES = 8 * 1024 * 1024; // >= 5 MiB S3 multipart minimum
export type UploadPurpose = 'media' | 'subtitle' | 'artwork';

const ALLOWED: Record<UploadPurpose, { exts: Set<string>; maxBytes?: number }> = {
  media: { exts: MEDIA_EXTENSIONS },
  subtitle: { exts: new Set(['.srt', '.vtt']), maxBytes: 5 * 1024 * 1024 },
  artwork: { exts: new Set(['.jpg', '.jpeg', '.png', '.webp']), maxBytes: 20 * 1024 * 1024 },
};

export interface CreateUploadInput {
  filename: string;
  totalBytes: number;
  purpose: UploadPurpose;
  /** Purpose specific: metadata overrides for media, {videoId, language, ...} for subtitles, {targetType, targetId} for artwork. */
  options?: Record<string, unknown>;
}

/**
 * Resumable chunked uploads: the client sends fixed-size chunks in any order (and may resend any chunk),
 * asks which chunks the server has to resume after interruption, then completes. Chunks are written
 * straight into a storage multipart upload, so any API replica can accept any chunk.
 */
@Injectable()
export class UploadsService {
  constructor(
    private readonly db: DbService,
    private readonly jobs: JobsService,
    private readonly audit: AuditService,
    @Inject(STORAGE) private readonly storage: StorageDriver,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {}

  async create(userId: string, input: CreateUploadInput) {
    const filename = safeFileName(input.filename);
    const ext = path.extname(filename).toLowerCase();
    const rule = ALLOWED[input.purpose];
    if (!rule) throw badRequest('invalid_purpose', 'Unknown upload purpose');
    if (!rule.exts.has(ext)) throw new AppError(415, 'unsupported_file_type', `Files of type ${ext || '(none)'} are not accepted for ${input.purpose}`);
    const max = Math.min(rule.maxBytes ?? Infinity, this.config.MAX_UPLOAD_BYTES);
    if (input.totalBytes > max) throw new AppError(413, 'file_too_large', `File exceeds the ${max} byte limit`);
    if (input.purpose === 'subtitle') {
      const o = input.options ?? {};
      if (typeof o.videoId !== 'string' || typeof o.language !== 'string') throw badRequest('missing_options', 'Subtitle uploads need options.videoId and options.language');
      const v = await this.db.one('SELECT id FROM videos WHERE id = $1', [o.videoId]);
      if (!v) throw notFound('Video');
    }
    if (input.purpose === 'artwork') {
      const o = input.options ?? {};
      if (!['album', 'artist', 'playlist'].includes(o.targetType as string) || typeof o.targetId !== 'string') {
        throw badRequest('missing_options', 'Artwork uploads need options.targetType (album|artist|playlist) and options.targetId');
      }
    }
    const row = await this.db.one(
      `INSERT INTO upload_sessions (created_by, filename, mime_type, total_bytes, chunk_bytes, purpose, options, storage_key, storage_upload, expires_at)
       VALUES ($1, $2, $3, $4, $5, $6, $7, '', '', now() + interval '24 hours') RETURNING id`,
      [userId, filename, contentTypeForFile(filename), input.totalBytes, CHUNK_BYTES, input.purpose, JSON.stringify(input.options ?? {})],
    );
    const key = `incoming/${row.id}/${filename}`;
    const uploadId = await this.storage.createMultipart(key, contentTypeForFile(filename));
    await this.db.query('UPDATE upload_sessions SET storage_key = $2, storage_upload = $3 WHERE id = $1', [row.id, key, uploadId]);
    return this.status(row.id, userId);
  }

  private async session(id: string, userId: string) {
    const s = await this.db.one('SELECT * FROM upload_sessions WHERE id = $1 AND created_by = $2', [id, userId]);
    if (!s) throw notFound('Upload');
    return s;
  }

  async status(id: string, userId: string) {
    const s = await this.session(id, userId);
    const totalChunks = Math.ceil(Number(s.total_bytes) / s.chunk_bytes);
    return {
      id: s.id,
      filename: s.filename,
      purpose: s.purpose,
      status: s.status,
      totalBytes: Number(s.total_bytes),
      chunkBytes: s.chunk_bytes,
      totalChunks,
      receivedChunks: [...s.received_chunks].sort((a: number, b: number) => a - b),
      missingChunks: Array.from({ length: totalChunks }, (_, i) => i).filter((i) => !s.received_chunks.includes(i)),
      jobId: s.job_id,
      expiresAt: s.expires_at,
    };
  }

  async putChunk(id: string, userId: string, index: number, data: Buffer) {
    const s = await this.session(id, userId);
    if (s.status !== 'open') throw conflict('upload_closed', `Upload is ${s.status}`);
    if (new Date(s.expires_at) < new Date()) throw conflict('upload_expired', 'Upload session expired');
    const totalChunks = Math.ceil(Number(s.total_bytes) / s.chunk_bytes);
    if (!Number.isInteger(index) || index < 0 || index >= totalChunks) throw badRequest('invalid_chunk', 'Chunk index out of range');
    const expected = index === totalChunks - 1 ? Number(s.total_bytes) - index * s.chunk_bytes : s.chunk_bytes;
    if (data.length !== expected) throw badRequest('invalid_chunk_size', `Chunk ${index} must be exactly ${expected} bytes`, { expected, received: data.length });
    const etag = await this.storage.uploadPart(s.storage_key, s.storage_upload, index + 1, data);
    await this.db.query(
      `UPDATE upload_sessions SET
         received_chunks = CASE WHEN $2 = ANY(received_chunks) THEN received_chunks ELSE array_append(received_chunks, $2) END,
         parts = parts || jsonb_build_object($2::text, $3::text)
       WHERE id = $1`,
      [id, index, etag],
    );
    return { index, received: true };
  }

  async complete(id: string, userId: string) {
    const s = await this.session(id, userId);
    if (s.status === 'completed') return { ...(await this.status(id, userId)) };
    if (s.status !== 'open') throw conflict('upload_closed', `Upload is ${s.status}`);
    const status = await this.status(id, userId);
    if (status.missingChunks.length) throw conflict('upload_incomplete', 'Some chunks are missing', { missingChunks: status.missingChunks.slice(0, 100) });
    // Claim the session atomically so concurrent "complete" calls create only one job.
    const claimed = await this.db.one(`UPDATE upload_sessions SET status = 'completed' WHERE id = $1 AND status = 'open' RETURNING id`, [id]);
    if (!claimed) return this.status(id, userId);
    const parts = Object.entries(s.parts as Record<string, string>).map(([i, etag]) => ({ partNumber: Number(i) + 1, etag }));
    await this.storage.completeMultipart(s.storage_key, s.storage_upload, parts);
    const stored = await this.storage.stat(s.storage_key);
    if (!stored || stored.size !== Number(s.total_bytes)) {
      await this.db.query(`UPDATE upload_sessions SET status = 'aborted' WHERE id = $1`, [id]);
      throw conflict('upload_corrupt', 'Assembled file size does not match the declared size');
    }
    const options = s.options ?? {};
    const base = { incomingKey: s.storage_key, filename: s.filename };
    const job =
      s.purpose === 'media'
        ? await this.jobs.create('ingest_audio', { ...base, overrides: options.overrides ?? {}, force: !!options.force }, userId, {
            source: 'upload',
            authorizationNote: options.authorizationNote ?? null,
          })
        : s.purpose === 'subtitle'
          ? await this.jobs.create('attach_subtitle', { ...base, ...options }, userId, { source: 'upload' })
          : await this.jobs.create('attach_artwork', { ...base, ...options }, userId, { source: 'upload' });
    await this.db.query('UPDATE upload_sessions SET job_id = $2 WHERE id = $1', [id, job.id]);
    await this.audit.record({ actorId: userId, action: 'upload.complete', targetType: 'upload', targetId: id, metadata: { filename: s.filename, bytes: Number(s.total_bytes) } });
    return { ...(await this.status(id, userId)), job };
  }

  async abort(id: string, userId: string) {
    const s = await this.session(id, userId);
    if (s.status !== 'open') return;
    await this.db.query(`UPDATE upload_sessions SET status = 'aborted' WHERE id = $1`, [id]);
    await this.storage.abortMultipart(s.storage_key, s.storage_upload).catch(() => undefined);
  }

  /** Housekeeping: abort sessions that were never completed. Run periodically by the worker. */
  async expireStale() {
    const stale = await this.db.query(
      `UPDATE upload_sessions SET status = 'expired' WHERE status = 'open' AND expires_at < now() RETURNING storage_key, storage_upload`,
    );
    for (const s of stale) await this.storage.abortMultipart(s.storage_key, s.storage_upload).catch(() => undefined);
    return stale.length;
  }
}
