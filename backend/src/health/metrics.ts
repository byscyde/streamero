import { collectDefaultMetrics, Counter, Histogram, Registry } from 'prom-client';

export const registry = new Registry();
collectDefaultMetrics({ register: registry, prefix: 'streamero_' });

export const httpDuration = new Histogram({
  name: 'streamero_http_request_duration_seconds',
  help: 'HTTP request duration',
  labelNames: ['method', 'route', 'status'],
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [registry],
});

export const jobsProcessed = new Counter({
  name: 'streamero_ingestion_jobs_total',
  help: 'Ingestion jobs processed',
  labelNames: ['type', 'status'],
  registers: [registry],
});
