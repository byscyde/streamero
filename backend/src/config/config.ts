import { z } from 'zod';

const csv = z
  .string()
  .default('')
  .transform((v) =>
    v
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean),
  );

const bool = z
  .union([z.boolean(), z.string()])
  .transform((v) => (typeof v === 'boolean' ? v : ['1', 'true', 'yes'].includes(v.toLowerCase())));

export const configSchema = z
  .object({
    NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
    PORT: z.coerce.number().int().positive().default(8080),
    PUBLIC_BASE_URL: z.string().url().default('http://localhost:8080'),
    CORS_ORIGINS: csv,
    DATABASE_URL: z.string().min(1),
    DATABASE_POOL_MAX: z.coerce.number().int().positive().default(10),
    REDIS_URL: z.string().min(1).default('redis://localhost:6379'),
    JWT_ACCESS_SECRET: z.string().min(32, 'JWT_ACCESS_SECRET must be at least 32 characters'),
    MEDIA_SIGNING_SECRET: z.string().min(32, 'MEDIA_SIGNING_SECRET must be at least 32 characters'),
    ACCESS_TOKEN_TTL_SECONDS: z.coerce.number().int().min(60).max(3600).default(900),
    REFRESH_TOKEN_TTL_DAYS: z.coerce.number().int().min(1).max(365).default(30),
    MEDIA_URL_TTL_SECONDS: z.coerce.number().int().min(60).max(86400).default(21600),
    STORAGE_DRIVER: z.enum(['local', 's3']).default('local'),
    STORAGE_LOCAL_ROOT: z.string().default('./data/storage'),
    S3_ENDPOINT: z.string().optional(),
    S3_REGION: z.string().default('us-east-1'),
    S3_BUCKET: z.string().default('streamero-media'),
    S3_ACCESS_KEY_ID: z.string().optional(),
    S3_SECRET_ACCESS_KEY: z.string().optional(),
    S3_FORCE_PATH_STYLE: bool.default(true),
    WORK_DIR: z.string().default('./data/work'),
    FFMPEG_PATH: z.string().default('ffmpeg'),
    FFPROBE_PATH: z.string().default('ffprobe'),
    FFMPEG_TIMEOUT_SECONDS: z.coerce.number().int().positive().default(7200),
    FFMPEG_THREADS: z.coerce.number().int().min(1).max(64).default(2),
    MAX_UPLOAD_BYTES: z.coerce.number().int().positive().default(20 * 1024 ** 3),
    WORKER_CONCURRENCY: z.coerce.number().int().min(1).max(16).default(1),
    IMPORT_ALLOWED_HOSTS: csv,
    IMPORT_ALLOWED_DIRS: csv,
    /** Development/testing only: allow URL imports from private/loopback addresses. */
    IMPORT_ALLOW_PRIVATE_NETWORKS: bool.default(false),
    SMTP_URL: z.string().optional().default(''),
    MAIL_FROM: z.string().default('STREAMERO <no-reply@scyde.dev>'),
    /** Base URL of the web player; email links become <base>reset-password?token=… and <base>verify-email?token=… */
    APP_LINK_BASE: z
      .string()
      .default('https://app.streamero.net/')
      .transform((v) => (v.endsWith('/') ? v : `${v}/`)),
    /** Worker looks up MusicBrainz metadata for freshly ingested tracks with missing tags (confidence >= 90 %). */
    METADATA_AUTOFILL: bool.default(false),
    /** MusicBrainz / Cover Art Archive endpoints (overridable for mirrors). */
    MUSICBRAINZ_BASE_URL: z.string().url().default('https://musicbrainz.org/ws/2'),
    COVERART_BASE_URL: z.string().url().default('https://coverartarchive.org'),
    APPLE_CLIENT_IDS: csv,
    YOUTUBE_API_KEY: z.string().optional().default(''),
    BOOTSTRAP_ADMIN_EMAIL: z.string().email().optional(),
    BOOTSTRAP_ADMIN_PASSWORD: z.string().optional().default(''),
    LOG_LEVEL: z.enum(['fatal', 'error', 'warn', 'info', 'debug', 'trace']).default('info'),
  })
  .superRefine((c, ctx) => {
    if (c.STORAGE_DRIVER === 's3' && (!c.S3_ACCESS_KEY_ID || !c.S3_SECRET_ACCESS_KEY)) {
      ctx.addIssue({ code: 'custom', message: 'S3 credentials are required when STORAGE_DRIVER=s3' });
    }
    if (c.NODE_ENV === 'production') {
      if (c.JWT_ACCESS_SECRET.startsWith('change-me') || c.MEDIA_SIGNING_SECRET.startsWith('change-me')) {
        ctx.addIssue({ code: 'custom', message: 'Placeholder secrets are not allowed in production' });
      }
      if (c.IMPORT_ALLOW_PRIVATE_NETWORKS) {
        ctx.addIssue({ code: 'custom', message: 'IMPORT_ALLOW_PRIVATE_NETWORKS must be false in production' });
      }
      if (!c.PUBLIC_BASE_URL.startsWith('https://') && !isLocalNetworkUrl(c.PUBLIC_BASE_URL)) {
        ctx.addIssue({ code: 'custom', message: 'PUBLIC_BASE_URL must use https in production (http is only allowed for localhost and private LAN addresses)' });
      }
    }
  });

/** http:// is acceptable only for loopback, RFC 1918 LAN addresses and .local hostnames (home-network installs). */
export function isLocalNetworkUrl(url: string): boolean {
  let host: string;
  try {
    const u = new URL(url);
    if (u.protocol !== 'http:') return false;
    host = u.hostname;
  } catch {
    return false;
  }
  if (host === 'localhost' || host.endsWith('.local')) return true;
  const m = host.match(/^(\d+)\.(\d+)\.(\d+)\.(\d+)$/);
  if (!m) return false;
  const [a, b] = [Number(m[1]), Number(m[2])];
  return a === 127 || a === 10 || (a === 192 && b === 168) || (a === 172 && b >= 16 && b <= 31) || (a === 100 && b >= 64 && b <= 127);
}

export type AppConfig = z.infer<typeof configSchema>;

export const APP_CONFIG = Symbol('APP_CONFIG');

export function loadConfig(env: NodeJS.ProcessEnv = process.env): AppConfig {
  const parsed = configSchema.safeParse(env);
  if (!parsed.success) {
    const details = parsed.error.issues.map((i) => `${i.path.join('.') || 'config'}: ${i.message}`).join('\n  ');
    throw new Error(`Invalid configuration:\n  ${details}`);
  }
  return parsed.data;
}
