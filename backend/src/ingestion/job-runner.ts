import { mkdir, copyFile } from 'node:fs/promises';
import path from 'node:path';
import { Inject, Injectable, Logger } from '@nestjs/common';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService } from '../db/db.service.js';
import { jobsProcessed } from '../health/metrics.js';
import { downloadUrl, listMediaFiles, resolveAllowedPath } from './importers.js';
import { JobsService } from './jobs.service.js';
import { JobFailure, MediaProcessor, type JobContext } from './processor.js';
import { safeFileName } from './metadata.js';

/** Executes one ingestion job and keeps its database row (status, progress, logs) up to date. */
@Injectable()
export class JobRunner {
  private readonly logger = new Logger(JobRunner.name);
  constructor(
    private readonly db: DbService,
    private readonly processor: MediaProcessor,
    private readonly jobs: JobsService,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {}

  private context(jobId: string): JobContext {
    let lastProgress = -1;
    let lastWrite = 0;
    return {
      jobId,
      log: async (message) => {
        this.logger.log({ jobId, message });
        await this.db.query(
          `UPDATE ingestion_jobs SET logs = (CASE WHEN jsonb_array_length(logs) > 500 THEN logs - 0 ELSE logs END)
             || jsonb_build_array(jsonb_build_object('at', now(), 'message', $2::text)) WHERE id = $1`,
          [jobId, message.slice(0, 2000)],
        );
      },
      progress: async (p) => {
        const v = Math.max(0, Math.min(100, Math.round(p)));
        // Throttle writes: at most every 2 s unless the value jumps or completes.
        if (v === lastProgress || (Date.now() - lastWrite < 2000 && v < 100 && v - lastProgress < 10)) return;
        lastProgress = v;
        lastWrite = Date.now();
        await this.db.query('UPDATE ingestion_jobs SET progress = $2 WHERE id = $1 AND progress <> $2', [jobId, v]);
      },
    };
  }

  /** Returns `true` if the failure is permanent and must not be retried. */
  async run(jobId: string, finalAttempt = true): Promise<{ ok: boolean; permanent: boolean; error?: string }> {
    const job = await this.db.one(
      `UPDATE ingestion_jobs SET status = 'running', attempts = attempts + 1, started_at = coalesce(started_at, now()), error = NULL
       WHERE id = $1 AND status IN ('queued', 'running', 'failed') RETURNING *`,
      [jobId],
    );
    if (!job) return { ok: true, permanent: true }; // cancelled or already done
    const ctx = this.context(jobId);
    try {
      const result = await this.dispatch(job, ctx);
      await this.db.query(
        `UPDATE ingestion_jobs SET status = 'succeeded', progress = 100, result = $2, finished_at = now() WHERE id = $1`,
        [jobId, JSON.stringify(result ?? {})],
      );
      jobsProcessed.inc({ type: job.type, status: 'succeeded' });
      return { ok: true, permanent: false };
    } catch (err: any) {
      const permanent = err instanceof JobFailure ? err.permanent : false;
      const message = (err?.message ?? String(err)).slice(0, 4000);
      const detail = err?.stderrTail ? `\n${String(err.stderrTail).slice(0, 2000)}` : '';
      await ctx.log(`Failed (attempt ${job.attempts}/${job.max_attempts}): ${message}${detail}`).catch(() => undefined);
      const terminal = permanent || finalAttempt || job.attempts >= job.max_attempts;
      await this.db.query(
        `UPDATE ingestion_jobs SET status = $2::job_status, error = $3, finished_at = CASE WHEN $2::text = 'failed' THEN now() END WHERE id = $1`,
        [jobId, terminal ? 'failed' : 'queued', message],
      );
      jobsProcessed.inc({ type: job.type, status: 'failed' });
      if (!(err instanceof JobFailure)) this.logger.error({ err, jobId }, 'Job crashed');
      return { ok: false, permanent: terminal, error: message };
    }
  }

  private async dispatch(job: any, ctx: JobContext) {
    const input = job.input;
    switch (job.type) {
      case 'ingest_audio':
      case 'ingest_video':
        return this.processor.ingestAuto(ctx, { incomingKey: input.incomingKey, filename: input.filename }, { overrides: input.overrides, force: input.force });
      case 'import_url':
        return this.processor.withWorkDir(`${job.id}-dl`, async (dir) => {
          await ctx.log(`Downloading ${redact(input.url)}`);
          const dest = path.join(dir, 'download.bin');
          const dl = await downloadUrl(input.url, dest, {
            allowedHosts: this.config.IMPORT_ALLOWED_HOSTS,
            allowPrivateNetworks: this.config.IMPORT_ALLOW_PRIVATE_NETWORKS,
            maxBytes: this.config.MAX_UPLOAD_BYTES,
          });
          await ctx.log(`Downloaded ${(dl.bytes / 1048576).toFixed(1)} MB (${dl.contentType ?? 'unknown type'})`);
          await ctx.progress(5);
          const filename = input.overrides?.filename ?? dl.filename;
          return this.processor.ingestAuto(ctx, { localPath: dest, filename: safeFileName(filename) }, {
            overrides: input.overrides,
            force: input.force,
            provenance: { ...job.provenance, finalUrl: redact(dl.finalUrl), bytes: dl.bytes },
          });
        });
      case 'import_path': {
        const real = await resolveAllowedPath(input.path, this.config.IMPORT_ALLOWED_DIRS);
        const files = await listMediaFiles(real);
        if (files.length === 0) throw new JobFailure('No media files found at this path');
        if (files.length > 1 || files[0] !== real) {
          // Folder import: fan out one job per file so each can fail/retry independently.
          const children = [];
          for (const f of files) {
            children.push((await this.jobs.create('import_path', { ...input, path: f }, job.created_by, { ...job.provenance, parentJobId: job.id })).id);
          }
          await ctx.log(`Queued ${children.length} file(s) from ${real}`);
          return { children };
        }
        return this.processor.withWorkDir(`${job.id}-fs`, async (dir) => {
          await mkdir(dir, { recursive: true });
          const dest = path.join(dir, `source${path.extname(real).toLowerCase()}`);
          await copyFile(real, dest);
          return this.processor.ingestAuto(ctx, { localPath: dest, filename: path.basename(real) }, {
            overrides: input.overrides,
            force: input.force,
            provenance: { ...job.provenance, sourcePath: real },
          });
        });
      }
      case 'attach_subtitle':
        return this.processor.attachSubtitle(ctx, input);
      case 'attach_artwork':
        return this.processor.attachArtwork(ctx, input);
      case 'reprocess':
        if (input.trackId) return this.processor.reprocessTrack(ctx, input.trackId);
        if (input.videoId) return this.processor.reprocessVideo(ctx, input.videoId);
        throw new JobFailure('Reprocess needs trackId or videoId');
      default:
        throw new JobFailure(`Unknown job type ${job.type}`);
    }
  }
}

/** Strips query strings (which often carry access tokens) from URLs before logging. */
export function redact(url: string) {
  try {
    const u = new URL(url);
    return `${u.origin}${u.pathname}${u.search ? '?…' : ''}`;
  } catch {
    return '[invalid url]';
  }
}
