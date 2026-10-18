import 'reflect-metadata';
import { hostname } from 'node:os';
import { Logger, Module } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { UnrecoverableError, Worker } from 'bullmq';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { CoreModule } from './core.module.js';
import { JobRunner } from './ingestion/job-runner.js';
import { bullConnection, INGESTION_QUEUE } from './ingestion/queue.js';
import { UploadsService } from './ingestion/uploads.service.js';
import { RedisService } from './redis/redis.module.js';

@Module({ imports: [CoreModule] })
class WorkerModule {}

/**
 * Media worker: a separate process (and container) that runs FFmpeg jobs. Scale it independently of
 * the API and constrain it with container CPU/memory limits (see infra/docker-compose.yml).
 */
async function main() {
  const app = await NestFactory.createApplicationContext(WorkerModule);
  app.enableShutdownHooks();
  const logger = new Logger('Worker');
  const config = app.get<AppConfig>(APP_CONFIG);
  const runner = app.get(JobRunner);
  const uploads = app.get(UploadsService);
  const redis = app.get(RedisService);

  const worker = new Worker(
    INGESTION_QUEUE,
    async (job) => {
      const finalAttempt = job.attemptsMade + 1 >= (job.opts.attempts ?? 1);
      const res = await runner.run(job.data.jobId, finalAttempt);
      if (!res.ok) {
        if (res.permanent) throw new UnrecoverableError(res.error ?? 'Job failed');
        throw new Error(res.error ?? 'Job failed');
      }
    },
    { connection: bullConnection(config.REDIS_URL), concurrency: config.WORKER_CONCURRENCY, lockDuration: 5 * 60_000 },
  );
  worker.on('failed', (job, err) => logger.warn({ jobId: job?.data?.jobId, err: err.message }, 'Job attempt failed'));

  const id = `${hostname()}:${process.pid}`;
  const beat = setInterval(() => {
    void redis.client.set(`worker:heartbeat:${id}`, new Date().toISOString(), 'EX', 60).catch(() => undefined);
    void uploads.expireStale().catch(() => undefined);
  }, 20_000);
  logger.log(`Worker ${id} started (concurrency ${config.WORKER_CONCURRENCY})`);

  const shutdown = async () => {
    clearInterval(beat);
    await worker.close();
    await app.close();
    process.exit(0);
  };
  process.on('SIGTERM', shutdown);
  process.on('SIGINT', shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
