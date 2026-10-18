# Testing

| Suite | Command | Needs | Count |
| --- | --- | --- | --- |
| Backend unit | `cd backend && npm run test:unit` | — | 34 |
| Backend integration | `cd backend && npm run test:int` | PostgreSQL (`streamero_test`), Redis (db 15), FFmpeg | 33 |
| Admin | `cd admin && npm test` | — | 4 |
| StreameroCore | `swift test --package-path ios/Packages/StreameroCore` | Swift 6 (macOS or Linux) | 33 |
| iOS unit + UI smoke | `xcodebuild test -scheme STREAMERO -destination 'platform=iOS Simulator,name=iPhone 16'` (after `xcodegen generate`) | macOS + Xcode | 5 + 1 |
| Stack smoke | `docker compose up -d --build --wait` + `curl /readyz` (CI `compose` job) | Docker | — |

Integration tests use `TEST_DATABASE_URL` / `TEST_REDIS_URL` (defaults in `test/setup-env.ts`); they drop and
recreate the schema of the test database. Media fixtures are generated with FFmpeg at test time (tagged 24-bit
FLAC with cover art, 128 kbps MP3, 50 s WAV for multi-chunk resumable upload, 720p MP4 with embedded subtitles,
corrupted bytes).

Covered failure cases: corrupted media (permanent failure + retry), duplicates, missing chunks, wrong chunk size,
expired/reused refresh tokens, disabled accounts, version conflicts (playlists, queue, preferences), stale
offline edits, revoked downloads, tampered media tokens, invalid ranges, path traversal keys, SSRF/private IPs,
YouTube import refusal, SQL-ish search input, offline token refresh (no sign-out), concurrent refresh coalescing.

Not automatable in CI (manual device checklist in IMPLEMENTATION_STATUS.md): background audio, calls/Siri,
Bluetooth disconnects, AirPlay, PiP, CarPlay, background downloads, real network slowness.
