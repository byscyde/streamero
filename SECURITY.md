# Security

Report vulnerabilities privately to the repository owner. Do not open public issues for security problems.

## Threat model (summary)

| Asset | Threats | Controls |
| --- | --- | --- |
| Accounts | Credential stuffing, brute force, enumeration, token theft | argon2id (OWASP params); constant-time-ish login with a real dummy hash; generic errors; Redis rate limits (10/min on auth, block 5 min) + nginx `limit_req`; 15-min access JWTs; rotating refresh tokens stored hashed, family revoked on reuse; password change/reset revokes sessions; disabled accounts rejected on every request |
| Authorisation | Privilege escalation, IDOR | Global guard; role read from DB per request; `@RequireRole` on admin routes; owner/collaborator checks on playlists (private playlists answer 404); user-scoped queries for all `/v1/me/*` data |
| Media | Hotlinking, scraping, storage key disclosure | Expiring AES-GCM sealed grants; storage keys never returned; downloads gated by server-side grants with renewal/revocation; originals never served to clients |
| Ingestion | Malicious files, command injection, SSRF, path traversal, zip/playlist tricks | Extension allow-list + FFprobe validation; FFmpeg via `spawn` without shell; `-format_whitelist` (no hls/concat/image2 on input) and `-protocol_whitelist file`; timeouts; worker container unprivileged, read-only, capability-free, resource-limited; URL importer: https only, host allow-list, YouTube hosts refused, redirects re-validated, private IPs refused **at connect time** (DNS-rebinding safe), size cap; folder importer: realpath must stay inside allowed dirs; storage keys validated against traversal |
| Uploads | Oversized/abusive uploads | Per-purpose size caps, 9 MB chunk body limit, exact chunk size checks, session expiry + cleanup, editor role required |
| Admin dashboard | XSS, clickjacking, CSRF | React escaping; strict CSP; `X-Frame-Options DENY`; bearer tokens (no cookies → no CSRF); refresh token in `sessionStorage` |
| Infrastructure | Exposed databases, secret leakage | Only nginx publishes a port; Postgres/Redis/S3 on an `internal: true` network; config validated at boot (placeholder secrets and plain-http public URLs rejected in production); secrets only via env; `.env` git-ignored |
| Privacy | Over-collection, log leakage | History and personalisation opt-out; data export and account deletion; logs redact `Authorization`, cookies, passwords, tokens and media tokens; no third-party analytics |

## Operational checklist

- Generate secrets with `openssl rand -base64 48`; rotate `MEDIA_SIGNING_SECRET` to invalidate all media links.
- Terminate TLS in front of nginx (Caddy, Traefik, a cloud LB) and set `PUBLIC_BASE_URL=https://…`.
- Give the application database user ownership of only the `streamero` database (it needs `CREATE` for
  migrations; for stricter setups run migrations with a separate owner role and grant DML to the runtime role).
- Keep `IMPORT_ALLOW_PRIVATE_NETWORKS=false` (the config refuses `true` in production).
- Monitor `/metrics` from the internal network only; nginx blocks it publicly.
- Run `npm audit --omit=dev` (CI does) and rebuild images regularly for FFmpeg/OS patches.
- Back up PostgreSQL and object storage (`scripts/backup.sh`) and test restores.
