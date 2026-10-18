# Implementation status

Last updated: 2026-10-18. "Verified" means an automated test or a reproducible manual check was actually run
in this repository's environment; the evidence column says which.

## Environment used

- Linux (Ubuntu 24.04) build host: Node 22, PostgreSQL 16, Redis 7, FFmpeg 6.1, Docker, Swift 6.1.2 for Linux.
- macOS: GitHub Actions `macos-15` runners (Xcode, iOS 18.5 simulator). **No physical iPhone, no CarPlay
  head unit, no Apple Developer signing assets were available.**

## Summary

| Area | Status | Evidence |
| --- | --- | --- |
| Backend API (auth, catalog, library, playlists, playback, search, home, recommendations, downloads, admin) | ✅ Implemented | 67 Vitest tests (34 unit, 33 integration against real PostgreSQL/Redis/FFmpeg) |
| Media ingestion (chunked uploads, FFprobe validation, renditions, HLS, artwork, subtitles, duplicates, retries) | ✅ Implemented | Integration tests ingest generated FLAC/MP3/WAV/MP4 with real FFmpeg; Docker stack E2E |
| Streaming (signed opaque URLs, Range, HLS + subtitle groups) | ✅ Implemented | Integration tests; E2E through nginx + S3 in Docker |
| Docker Compose stack (nginx, API, worker, PostgreSQL, Redis, SeaweedFS S3) | ✅ Implemented | Built and run; upload → worker → stream verified |
| Backups | ✅ Implemented | `scripts/backup.sh` run on the live stack; dump restored into a scratch DB and row counts checked |
| Admin dashboard | ✅ Implemented | Typecheck, 4 unit tests, production build, browser screenshots against the live API |
| StreameroCore (Swift) | ✅ Implemented | 33 XCTests on Linux (and in CI), including contract tests decoding real API responses |
| iOS app compiles & unsigned IPA builds | ✅ Verified in CI | `iOS` workflow: build job produced `STREAMERO-*-unsigned.ipa` |
| iOS unit + UI smoke tests | ✅ Verified in CI | 5 unit tests + 1 UI test on iPhone 16 Pro simulator (iOS 18.5) |
| iOS features on a real device (audio, background, lock screen, Bluetooth, AirPlay, PiP, downloads) | ⚠️ Implemented, **not device-tested** | Requires a physical iPhone; see checklist below |
| CarPlay | ⚠️ Implemented, **blocked** on Apple entitlement | Needs `com.apple.developer.carplay-audio` approved for your team |
| Sign in with Apple | ⚠️ Implemented, not exercised | Needs an Apple Developer team, Services ID, and `APPLE_CLIENT_IDS` |
| Signed IPA / TestFlight / App Store | ⛔ Blocked | Needs signing certificate + provisioning profile; scripts provided |

## Feature checklist

### Accounts & security
- [x] Email registration, login, email verification, password reset, change password
- [x] Short-lived access tokens, rotating refresh tokens with reuse detection (bug found and fixed by a test)
- [x] Keychain storage on iOS (`AfterFirstUnlockThisDeviceOnly`)
- [x] Roles user/editor/admin enforced server-side; last-admin protection
- [x] Profile, avatar (magic-byte validated), preferences sync, data export, account deletion, session list/revoke
- [x] Rate limiting (Redis-backed), audit log, structured logs with secret redaction
- [~] Sign in with Apple — server verification + client button implemented; untested against Apple

### Catalog, search, discovery
- [x] Artists (top tracks, chronological albums/singles/compilations, videos, related, follow)
- [x] Albums (multi-disc, explicit markers, save, more-by-artist, related)
- [x] Playlists (create, edit, visibility, share links, reorder/move/remove with versions, collaborators API)
- [~] Collaborative playlists — server supports collaborators; the app has no invite UI yet
- [x] Search: prefix full-text + trigram typo tolerance, filters, pagination, suggestions, recent searches
- [x] Backend-driven home feed with configurable sections (admin editor)
- [x] Explainable rule-based recommendations, mixes, trending, explicit filter, personalisation off switch

### Music player (iOS)
- [x] Play/pause/seek/next/previous, queue editing, shuffle, repeat off/all/one, speed, sleep timer (with fade)
- [x] Gapless (pre-queued AVQueuePlayer item) and equal-power crossfade (two decks)
- [x] Quality profiles per network + Low Data Mode; delivered vs. source quality shown; lossless only when delivered
- [x] Lock screen / Control Center / remote commands, Now Playing metadata and artwork
- [x] Interruptions, route changes (pause on headphone/Bluetooth disconnect), media-services reset, stream retry
- [x] Queue + position persisted on device and synced across devices; listening history outbox
- [x] Synced (LRC) and plain lyrics with attribution; tap a line to seek
- [~] Word-level lyric timing is parsed and exposed (`wordsSung`) but the UI highlights whole lines
- [ ] Volume normalisation (ReplayGain/loudness) — not implemented; the setting was removed rather than faked

### Video
- [x] HLS adaptive streaming, manual quality cap, speed, PiP, AirPlay, audio track menu (HLS renditions)
- [x] Subtitles: SRT/WebVTT upload, embedded text subtitles, HLS subtitle groups, custom overlay (size, background,
      sync offset), auto-selection by preferred languages, forced subtitles, captions/descriptions kinds
- [x] Resume positions, continue watching, up-next autoplay, audio-only background listening for videos
- [~] Timeline preview sprites are generated and returned by the API; the app does not render them while
      scrubbing (system player controls are used)
- [ ] Bitmap subtitles (PGS/VobSub) — skipped during ingestion with a log entry (cannot become WebVTT without OCR)

### Offline
- [x] Server-issued download grants, quality choice, Wi-Fi-only, progress, pause/resume, retry, SHA-256 integrity
- [x] Offline library playback, storage usage, delete one/all, licence renewal and revocation handling
- [x] HLS video downloads with sidecar subtitles

### Admin
- [x] Overview, uploads (resumable, drag & drop), URL/folder imports with authorisation notes, job queue with logs,
      retry/cancel, tracks (edit, bulk actions, lyrics), albums, artists, artwork upload, videos + subtitles,
      users & roles, home feed, storage, activity, audit log, system health, non-secret config

### YouTube
- [x] Discovery via YouTube Data API v3 (needs `YOUTUBE_API_KEY`), official IFrame embed in the app (foreground)
- [x] Importer refuses YouTube/googlevideo URLs, even if allow-listed
- [~] Not exercised against the real YouTube API (no key in this environment)

## Physical-device test checklist (not yet run)

- [ ] Background playback for 30+ minutes with the screen locked; stream URL refresh after expiry
- [ ] Incoming call / Siri / alarm interruption and resume; navigation prompt ducking (Maps)
- [ ] AirPods and car Bluetooth connect/disconnect; AirPlay to a speaker and an Apple TV
- [ ] Gapless album transition and crossfade audibility; lossless ALAC on wired output
- [ ] PiP from the video player; subtitles in native and overlay modes; external display
- [ ] Downloads in background with app suspended/terminated; Wi-Fi-only enforcement
- [ ] CarPlay Simulator (Xcode › Open Developer Tool) and a real vehicle, once the entitlement is granted
- [ ] VoiceOver and Dynamic Type pass on all screens

## Known limitations

- Recommendations sample up to 2,000 candidate tracks per request (`ORDER BY random()`); large catalogs need a
  candidate-generation step (documented in DECISIONS.md, ADR-009).
- Search uses PostgreSQL; a dedicated engine can replace `SearchService` behind the same API.
- Lyrics must be supplied/licensed by the operator; STREAMERO does not fetch lyrics from third parties.
