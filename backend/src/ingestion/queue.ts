import { Queue, type JobsOptions } from 'bullmq';
import { Redis } from 'ioredis';

export const INGESTION_QUEUE = 'ingestion';

export interface IngestionQueue {
  enqueue(jobId: string, attempts: number): Promise<void>;
  remove(jobId: string): Promise<void>;
  counts(): Promise<Record<string, number>>;
  close(): Promise<void>;
}

export function bullConnection(url: string) {
  // BullMQ workers require maxRetriesPerRequest = null for blocking commands.
  return new Redis(url, { maxRetriesPerRequest: null });
}

export class BullIngestionQueue implements IngestionQueue {
  private readonly queue: Queue;
  private readonly connection: Redis;

  constructor(redisUrl: string) {
    this.connection = bullConnection(redisUrl);
    this.queue = new Queue(INGESTION_QUEUE, { connection: this.connection });
  }

  async enqueue(jobId: string, attempts: number) {
    const opts: JobsOptions = {
      // One BullMQ job per (re)enqueue; the database row stays the source of truth for status.
      jobId: `${jobId}-${Date.now()}`,
      attempts,
      backoff: { type: 'exponential', delay: 30_000 },
      removeOnComplete: { age: 7 * 86400, count: 5000 },
      removeOnFail: { age: 30 * 86400 },
    };
    await this.queue.add('run', { jobId }, opts);
  }

  async remove(jobId: string) {
    const jobs = await this.queue.getJobs(['waiting', 'delayed', 'prioritized']);
    await Promise.all(jobs.filter((j) => j.data?.jobId === jobId).map((j) => j.remove().catch(() => undefined)));
  }

  async counts() {
    return this.queue.getJobCounts('waiting', 'active', 'delayed', 'failed', 'completed');
  }

  async close() {
    await this.queue.close();
    await this.connection.quit().catch(() => undefined);
  }
}
