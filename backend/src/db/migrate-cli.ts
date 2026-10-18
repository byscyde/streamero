import { loadConfig } from '../config/config.js';
import { migrate } from './migrate.js';

const config = loadConfig();
migrate(config.DATABASE_URL, undefined, (m) => console.log(m))
  .then((ran) => {
    console.log(ran.length ? `Applied ${ran.length} migration(s)` : 'Database is up to date');
  })
  .catch((err) => {
    console.error(err.message);
    process.exit(1);
  });
