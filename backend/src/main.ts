import { loadConfig } from './config/config.js';
import { bootstrapAdmin } from './db/bootstrap-admin.js';
import { migrate } from './db/migrate.js';
import { createApp } from './bootstrap.js';

async function main() {
  const config = loadConfig();
  if (process.env.MIGRATE_ON_START !== 'false') await migrate(config.DATABASE_URL, undefined, (m) => console.log(m));
  await bootstrapAdmin(config).catch((err) => console.error('Admin bootstrap failed', err));
  const app = await createApp();
  await app.listen(config.PORT, '0.0.0.0');
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
