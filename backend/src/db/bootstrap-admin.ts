import { hash } from '@node-rs/argon2';
import pg from 'pg';
import type { AppConfig } from '../config/config.js';

/** Creates the first administrator from BOOTSTRAP_ADMIN_* when no administrator exists. Idempotent. */
export async function bootstrapAdmin(config: AppConfig, log: (m: string) => void = console.log): Promise<'created' | 'exists' | 'skipped'> {
  const client = new pg.Client({ connectionString: config.DATABASE_URL });
  await client.connect();
  try {
    const existing = await client.query(`SELECT 1 FROM users WHERE role = 'admin' LIMIT 1`);
    if (existing.rowCount) return 'exists';
    if (!config.BOOTSTRAP_ADMIN_EMAIL || config.BOOTSTRAP_ADMIN_PASSWORD.length < 12) {
      log('No administrator exists. Set BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD (min 12 chars) to create one.');
      return 'skipped';
    }
    const passwordHash = await hash(config.BOOTSTRAP_ADMIN_PASSWORD, { memoryCost: 19456, timeCost: 2, parallelism: 1 });
    await client.query(
      `INSERT INTO users (email, password_hash, display_name, role, email_verified_at) VALUES ($1, $2, 'Administrator', 'admin', now())
       ON CONFLICT (email) DO UPDATE SET role = 'admin'`,
      [config.BOOTSTRAP_ADMIN_EMAIL, passwordHash],
    );
    log(`Administrator ${config.BOOTSTRAP_ADMIN_EMAIL} created.`);
    return 'created';
  } finally {
    await client.end();
  }
}
