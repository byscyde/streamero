import { loadConfig } from '../config/config.js';
import { bootstrapAdmin } from './bootstrap-admin.js';
import { migrate } from './migrate.js';

const config = loadConfig();
await migrate(config.DATABASE_URL);
const result = await bootstrapAdmin(config);
if (result === 'skipped') process.exitCode = 1;
if (result === 'exists') console.log('An administrator already exists; nothing to do.');
