import { writeFile } from 'node:fs/promises';
import { buildOpenApi, createApp } from './bootstrap.js';

/** Writes the OpenAPI document without starting the HTTP server: `npm run openapi -- ../docs/openapi.json` */
const out = process.argv[2] ?? 'openapi.json';
const app = await createApp({ logger: false });
await writeFile(out, JSON.stringify(buildOpenApi(app), null, 2));
await app.close();
console.log(`OpenAPI written to ${out}`);
process.exit(0);
