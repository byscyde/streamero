import { Inject, Injectable } from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { badRequest, conflict, notFound } from '../common/errors.js';
import { toPage, type PageQuery } from '../common/pagination.js';
import { DbService } from '../db/db.service.js';
import type { IngestionQueue } from './queue.js';

export const INGESTION_QUEUE_TOKEN = Symbol('INGESTION_QUEUE');

export type JobType = 'ingest_audio' | 'ingest_video' | 'import_url' | 'import_path' | 'attach_subtitle' | 'attach_artwork' | 'reprocess';

@Injectable()
export class JobsService {
  constructor(
    private readonly db: DbService,
    private readonly audit: AuditService,
    @Inject(INGESTION_QUEUE_TOKEN) private readonly queue: IngestionQueue,
  ) {}

  async create(type: JobType, input: Record<string, unknown>, createdBy: string | null, provenance: Record<string, unknown> = {}, maxAttempts = 3) {
    const job = await this.db.one(
      `INSERT INTO ingestion_jobs (type, input, created_by, provenance, max_attempts) VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [type, JSON.stringify(input), createdBy, JSON.stringify(provenance), maxAttempts],
    );
    await this.queue.enqueue(job.id, maxAttempts);
    await this.audit.record({ actorId: createdBy, action: `job.create.${type}`, targetType: 'ingestion_job', targetId: job.id });
    return present(job);
  }

  async list(page: PageQuery, status?: string, type?: string) {
    const rows = await this.db.query(
      `SELECT j.*, u.email AS created_by_email, count(*) OVER () AS total FROM ingestion_jobs j LEFT JOIN users u ON u.id = j.created_by
       WHERE ($3::job_status IS NULL OR j.status = $3) AND ($4::job_type IS NULL OR j.type = $4)
       ORDER BY j.created_at DESC LIMIT $1 OFFSET $2`,
      [page.limit + 1, page.offset, status ?? null, type ?? null],
    );
    return toPage(rows.map(present), page, rows[0] ? Number(rows[0].total) : 0);
  }

  async get(id: string) {
    const row = await this.db.one('SELECT * FROM ingestion_jobs WHERE id = $1', [id]);
    if (!row) throw notFound('Job');
    return { ...present(row), logs: row.logs, input: row.input };
  }

  async retry(id: string, actorId: string) {
    const row = await this.db.one(
      `UPDATE ingestion_jobs SET status = 'queued', progress = 0, error = NULL, attempts = 0, started_at = NULL, finished_at = NULL,
         logs = logs || jsonb_build_array(jsonb_build_object('at', now(), 'message', 'Retry requested'))
       WHERE id = $1 AND status IN ('failed', 'cancelled') RETURNING *`,
      [id],
    );
    if (!row) throw conflict('not_retryable', 'Only failed or cancelled jobs can be retried');
    await this.queue.enqueue(id, row.max_attempts);
    await this.audit.record({ actorId, action: 'job.retry', targetType: 'ingestion_job', targetId: id });
    return present(row);
  }

  async cancel(id: string, actorId: string) {
    const row = await this.db.one(
      `UPDATE ingestion_jobs SET status = 'cancelled', finished_at = now() WHERE id = $1 AND status = 'queued' RETURNING *`,
      [id],
    );
    if (!row) throw badRequest('not_cancellable', 'Only queued jobs can be cancelled');
    await this.queue.remove(id);
    await this.audit.record({ actorId, action: 'job.cancel', targetType: 'ingestion_job', targetId: id });
    return present(row);
  }

  async stats() {
    const [byStatus, queue] = await Promise.all([
      this.db.query(`SELECT status, count(*)::int AS n FROM ingestion_jobs GROUP BY status`),
      this.queue.counts().catch(() => ({})),
    ]);
    return { jobs: Object.fromEntries(byStatus.map((r) => [r.status, r.n])), queue };
  }
}

function present(r: any) {
  return {
    id: r.id,
    type: r.type,
    status: r.status,
    progress: r.progress,
    attempts: r.attempts,
    maxAttempts: r.max_attempts,
    error: r.error,
    result: r.result,
    provenance: r.provenance,
    createdBy: r.created_by_email ?? r.created_by,
    createdAt: r.created_at,
    startedAt: r.started_at,
    finishedAt: r.finished_at,
    filename: r.input?.filename ?? r.input?.url ?? r.input?.path ?? null,
  };
}
