import { execFileSync } from 'node:child_process';
import { mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import pg from 'pg';
import request from 'supertest';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { createApp } from '../src/bootstrap.js';
import { migrate } from '../src/db/migrate.js';
import { DbService } from '../src/db/db.service.js';
import { JobRunner } from '../src/ingestion/job-runner.js';

export async function resetDatabase() {
  const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  await client.query('DROP SCHEMA public CASCADE; CREATE SCHEMA public;');
  await client.end();
  await migrate(process.env.DATABASE_URL!);
}

export interface TestContext {
  app: NestExpressApplication;
  http: ReturnType<typeof request>;
  db: DbService;
  runner: JobRunner;
  close(): Promise<void>;
}

export async function startApp(): Promise<TestContext> {
  await resetDatabase();
  const app = await createApp({ logger: false });
  await app.init();
  return {
    app,
    http: request(app.getHttpServer()),
    db: app.get(DbService),
    runner: app.get(JobRunner),
    close: () => app.close(),
  };
}

let counter = 0;
export async function registerUser(ctx: TestContext, role: 'user' | 'editor' | 'admin' = 'user') {
  const email = `user${++counter}-${Date.now()}@example.test`;
  const res = await ctx.http.post('/v1/auth/register').send({ email, password: 'correct-horse-42', displayName: `Test ${role} ${counter}` }).expect(201);
  if (role !== 'user') await ctx.db.query('UPDATE users SET role = $2 WHERE id = $1', [res.body.user.id, role]);
  return { email, password: 'correct-horse-42', id: res.body.user.id as string, token: res.body.accessToken as string, refreshToken: res.body.refreshToken as string };
}

export const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

export const fixturesDir = path.join(tmpdir(), `streamero-fixtures-${process.pid}`);
mkdirSync(fixturesDir, { recursive: true });

/** Generates real media with FFmpeg so tests exercise the actual pipeline. */
export function makeFixture(name: string, args: string[]): string {
  const out = path.join(fixturesDir, name);
  execFileSync('ffmpeg', ['-v', 'error', '-y', ...args, out]);
  return out;
}

/** Uploads a file through the resumable chunk API (optionally sending chunks out of order). */
export async function uploadFile(ctx: TestContext, token: string, file: Buffer, filename: string, purpose: 'media' | 'subtitle' | 'artwork', options: object = {}, reverse = false) {
  const created = await ctx.http.post('/v1/admin/uploads').set(auth(token)).send({ filename, totalBytes: file.length, purpose, options }).expect(201);
  const { id, chunkBytes, totalChunks } = created.body;
  const order = [...Array(totalChunks).keys()];
  if (reverse) order.reverse();
  for (const i of order) {
    await ctx.http
      .put(`/v1/admin/uploads/${id}/chunks/${i}`)
      .set(auth(token))
      .set('Content-Type', 'application/octet-stream')
      .send(file.subarray(i * chunkBytes, Math.min(file.length, (i + 1) * chunkBytes)))
      .expect(200);
  }
  const done = await ctx.http.post(`/v1/admin/uploads/${id}/complete`).set(auth(token)).expect(200);
  return done.body as { id: string; job: { id: string } };
}
