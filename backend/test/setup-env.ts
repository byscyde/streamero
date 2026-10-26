import { tmpdir } from 'node:os';
import path from 'node:path';

const root = path.join(tmpdir(), `streamero-test-${process.pid}`);
Object.assign(process.env, {
  NODE_ENV: 'test',
  DATABASE_URL: process.env.TEST_DATABASE_URL ?? 'postgres://streamero:streamero@localhost:5432/streamero_test',
  REDIS_URL: process.env.TEST_REDIS_URL ?? 'redis://localhost:6379/15',
  JWT_ACCESS_SECRET: 'test-access-secret-that-is-long-enough-123',
  MEDIA_SIGNING_SECRET: 'test-media-secret-that-is-long-enough-456',
  PUBLIC_BASE_URL: 'http://127.0.0.1:0',
  STORAGE_DRIVER: 'local',
  STORAGE_LOCAL_ROOT: path.join(root, 'storage'),
  WORK_DIR: path.join(root, 'work'),
  LOG_LEVEL: 'error',
  FFMPEG_THREADS: '2',
  GOOGLE_WEB_CLIENT_ID: 'test-web.apps.googleusercontent.com',
});
