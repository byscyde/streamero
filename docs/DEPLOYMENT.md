# Deployment

## Single host (Docker Compose)

```bash
git clone <repo> streamero && cd streamero
cp .env.example .env
# Required: POSTGRES_PASSWORD, S3_SECRET_KEY, JWT_ACCESS_SECRET, MEDIA_SIGNING_SECRET (openssl rand -base64 48),
#           BOOTSTRAP_ADMIN_PASSWORD (≥ 12 chars), PUBLIC_BASE_URL=https://music.example.com
docker compose up -d --build
docker compose ps            # api healthy; worker running
curl -fsS http://localhost:8088/readyz
```

The first administrator is created from `BOOTSTRAP_ADMIN_EMAIL`/`BOOTSTRAP_ADMIN_PASSWORD` on API start (only if no
admin exists). Remove the password from `.env` afterwards. Admin UI: `/admin/`. API docs: `/docs`.

### Existing nginx on the host

Run `sudo ./scripts/install-server.sh` and choose *existing nginx*, or use `docker-compose.localhost.yml`
(binds STREAMERO to 127.0.0.1:8088) plus the vhost in `infra/host-nginx-streamero.conf` and certbot.
Step-by-step (Croatian): [INSTALACIJA_SERVERA.md](INSTALACIJA_SERVERA.md).

### TLS

Put a TLS terminator in front of nginx's port, e.g. Caddy:

```
music.example.com {
  reverse_proxy 127.0.0.1:8088
}
```

Set `PUBLIC_BASE_URL=https://music.example.com` (the API refuses plain-http public URLs in production except
localhost). Keep `HTTP_PORT` bound to localhost or firewalled when a proxy is in front.

### Email

Set `SMTP_URL` (e.g. `smtps://user:pass@smtp.example.com:465`) and `MAIL_FROM`. Without SMTP, verification and
reset emails cannot be delivered in production.

### External object storage

Use AWS S3, Cloudflare R2, Backblaze B2, Wasabi or Garage by setting `S3_ENDPOINT`, `S3_REGION`, `S3_BUCKET`,
`S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` for `api` and `worker` (and dropping the `s3` service). The bucket must
be private; the API serves media through signed URLs.

### Media imports

- URL imports: `IMPORT_ALLOWED_HOSTS=media.example.com,.cdn.example.org` (leading dot = subdomains).
- Server folders: mount a read-only volume into the worker and set `IMPORT_ALLOWED_DIRS=/import`:
  ```yaml
  worker:
    volumes: ["/srv/music:/import:ro", "work:/data/work"]
  ```

### Optional integrations

- Sign in with Apple: `APPLE_CLIENT_IDS=com.yourco.streamero` (the app's bundle id; add a Services ID for web).
- YouTube discovery: `YOUTUBE_API_KEY` (YouTube Data API v3, restricted to that API).

## Scaling

- **API** is stateless: run several replicas behind nginx/LB. Rate limits and the queue use Redis; uploads use S3
  multipart, so chunks may hit any replica. Migrations run on start under an advisory lock.
- **Workers** scale independently (`docker compose up -d --scale worker=3`); tune `WORKER_CONCURRENCY`,
  `FFMPEG_THREADS`, `WORKER_CPUS`, `WORKER_MEMORY`. Transcoding is CPU-bound.
- **Media delivery**: put a CDN in front of `/v1/media/*` (tokens are in the path; responses carry
  `Cache-Control: private`, so configure the CDN to cache by full path for the grant lifetime).
- **PostgreSQL**: managed Postgres 16 with PITR is recommended for production.

## Monitoring

- Liveness `GET /healthz`, readiness `GET /readyz` (DB, Redis, storage).
- Prometheus metrics at `api:8080/metrics` (internal only): HTTP latency histogram, ingestion job counters,
  Node runtime metrics.
- Structured JSON logs (pino) with request ids (`X-Request-Id`); secrets and media tokens are redacted.
- Admin › System health shows dependency checks, worker heartbeats, queue depth and applied migrations.

## Upgrades

```bash
git pull && docker compose up -d --build   # migrations apply automatically; back up first (BACKUP.md)
```
