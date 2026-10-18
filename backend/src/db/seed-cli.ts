import pg from 'pg';
import { hash } from '@node-rs/argon2';
import { loadConfig } from '../config/config.js';
import { migrate } from './migrate.js';

/** Creates the first administrator from BOOTSTRAP_ADMIN_* if no administrator exists yet. Idempotent. */
const config = loadConfig();
await migrate(config.DATABASE_URL);
const client = new pg.Client({ connectionString: config.DATABASE_URL });
await client.connect();
const existing = await client.query(`SELECT 1 FROM users WHERE role = 'admin' LIMIT 1`);
if (existing.rowCount) {
  console.log('An administrator already exists; nothing to do.');
} else if (!config.BOOTSTRAP_ADMIN_EMAIL || config.BOOTSTRAP_ADMIN_PASSWORD.length < 12) {
  console.error('Set BOOTSTRAP_ADMIN_EMAIL and BOOTSTRAP_ADMIN_PASSWORD (min 12 chars) to create the first administrator.');
  process.exitCode = 1;
} else {
  const passwordHash = await hash(config.BOOTSTRAP_ADMIN_PASSWORD, { memoryCost: 19456, timeCost: 2, parallelism: 1 });
  await client.query(
    `INSERT INTO users (email, password_hash, display_name, role, email_verified_at) VALUES ($1, $2, 'Administrator', 'admin', now())
     ON CONFLICT (email) DO UPDATE SET role = 'admin'`,
    [config.BOOTSTRAP_ADMIN_EMAIL, passwordHash],
  );
  console.log(`Administrator ${config.BOOTSTRAP_ADMIN_EMAIL} created.`);
}
await client.end();
