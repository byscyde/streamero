# STREAMERO architecture

```
 iPhone / iPad / CarPlay                         Web
 ┌───────────────────────────┐            ┌──────────────┐
 │ STREAMERO (SwiftUI)        │            │ Admin (React)│
 │  AudioPlayer (2× AVQueue)  │            └──────┬───────┘
 │  Video (AVPlayerVC, PiP)   │                   │ same REST API + auth
 │  DownloadManager (SwiftData│                   │
 │  CarPlay templates         │                   │
 │  StreameroCore (pure Swift)│                   │
 └────────────┬──────────────┘                   │
              │ HTTPS: JSON API, signed media URLs, HLS
        ┌─────▼──────────────────────────────────▼─────┐
        │ nginx — TLS, rate limits, admin static files  │  (only public port)
        └─────┬─────────────────────────────────────────┘
              │ internal network
   ┌──────────▼───────────┐   BullMQ   ┌──────────────────────┐
   │ API (NestJS)          │──────────▶│ Worker (same image)  │
   │ auth, catalog, search │   Redis   │ FFprobe/FFmpeg, HLS, │
   │ library, playlists,   │◀──────────│ artwork, subtitles   │
   │ streaming grants,     │  progress │ (unprivileged, CPU/  │
   │ admin, recommendations│  via DB   │  memory limited)     │
   └───┬─────────┬─────────┘           └───┬────────┬────────┘
       │         │                         │        │
  PostgreSQL   Redis (rate limits,      S3-compatible object storage
  (metadata,   queue, cache)            (originals, renditions, HLS,
   users, …)                             artwork, subtitles)
```

## Backend

- **NestJS 12 (ESM) modules**: `auth`, `users`, `catalog`, `streaming`, `library`, `playlists`, `playback`,
  `search`, `recommendations`, `home`, `downloads`, `youtube`, `admin`, `ingestion`, `health`. Infrastructure
  modules (`db`, `redis`, `storage`, `audit`, `mail`, `config`) are global and shared with the worker.
- **Data access** is hand-written SQL through `pg` with shared projections (`catalog/presenters.ts`). Every list
  endpoint is one query (correlated subqueries for counts/flags) — no N+1. Pagination fetches `limit + 1` rows.
- **Schema**: forward-only SQL migrations (`backend/migrations`), checksummed, applied under an advisory lock.
  UUID primary keys, foreign keys everywhere, `RESTRICT` on media originals so media can't be orphaned silently.
- **Auth**: argon2id passwords; 15-min HS256 access JWTs; opaque 48-byte refresh tokens stored as SHA-256 hashes,
  rotated on every use with family-wide revocation on reuse. The global guard re-reads the user's role and
  disabled flag from the database on every request. Google sign-in verifies ID tokens against Google's JWKS (issuer, audience = configured client IDs, nonce, verified email).
- **Errors**: `{ error: { code, message, details? }, requestId }` with stable machine codes.
- **Rate limiting**: `@nestjs/throttler` with a Redis Lua storage shared by all replicas; stricter limits on auth.

## Media pipeline

1. **Upload**: resumable 8 MiB chunks (any order, re-sendable) written straight into an S3 multipart upload, so any
   API replica can take any chunk. Completion verifies the assembled size and enqueues a job.
2. **Worker**: downloads the source into a private work dir, runs **FFprobe with a demuxer allow-list and
   `-protocol_whitelist file`** (crafted playlists/concat files cannot read other files or URLs), decides audio vs.
   video from the actual streams, checks duplicates by SHA-256, stores the untouched original, extracts tags and
   embedded artwork, and builds renditions.
3. **Audio renditions** (`media/profiles.ts`): `data_saver` (AAC ≤96k), `standard` (≤160k), `high` (≤256k), and
   `lossless` (ALAC) **only when the source is lossless**. Compatible AAC/MP3 originals within a profile's bitrate
   are reused instead of re-encoded; lossy sources are never "upscaled".
4. **Video**: HLS (MPEG-TS, 6 s segments, aligned GOPs) ladder 360/540/720/1080 capped at source height, separate
   AAC audio renditions per source audio track (language-tagged), thumbnail, timeline-preview sprite sheets,
   an audio-only AAC rendition, and embedded text subtitles converted to WebVTT.
5. **Subtitles**: SRT/VTT uploads are decoded (UTF-8/UTF-16/Windows-1252), normalised to WebVTT with optional sync
   offset, original preserved. The master playlist is rewritten at request time to add `EXT-X-MEDIA TYPE=SUBTITLES`
   groups, with `X-TIMESTAMP-MAP` injected so cues align with MPEG-TS timestamps.
6. **Deletion** goes through `AssetsService.deleteIfUnreferenced`, which checks every referencing column before
   removing bytes.

## Streaming & access control

The client asks `GET /v1/tracks/:id/stream?profile=` (or `/v1/videos/:id/stream`). The API picks the best available
rendition (falling *down* in quality first) and returns an expiring URL `/v1/media/<token>[/<path>]`. Tokens are
AES-256-GCM sealed grants (opaque storage key or HLS prefix + expiry + viewer), so AVPlayer, AirPlay receivers and
HLS relative segment URLs work without bearer headers, and storage keys never reach clients. Byte ranges are
supported. A CDN can front `/v1/media/*` because tokens are in the path.

## iOS app

- **StreameroCore** (Swift package, Swift 6 strict concurrency): Codable models, `APIClient` with an `AuthManager`
  actor (coalesced refresh, one retry on 401, offline-safe), `PlaybackQueue` state machine (shuffle preserving the
  current item, repeat off/all/one, previous-after-3-s), LRC and WebVTT parsers with binary-search timelines,
  offline change queue (coalescing, LWW), listening sessions, sleep timer, pure-Swift SHA-256.
- **App** (SwiftUI, Observation, iOS 17): `AppModel` composition root; `AudioPlayer` with two `AVQueuePlayer` decks
  (gapless via pre-queued next item; equal-power crossfade by running the idle deck), `AVAudioSession` long-form
  playback, interruption/route-change handling, `MPRemoteCommandCenter` + `MPNowPlayingInfoCenter`, stream retry with
  fresh URLs, queue snapshot persisted locally and synced (compare-and-swap) to the server.
- **Video**: `AVPlayerViewController` (system controls, PiP, AirPlay, audio track menu) plus a custom subtitle
  overlay (size, background, sync offset), manual quality caps via `preferredMaximumResolution`, resume points.
- **Downloads**: SwiftData records; background `URLSession` for audio files (pause/resume data, SHA-256 verified),
  `AVAssetDownloadURLSession` for HLS video; licences renewed/revoked via `/v1/me/downloads/validate`.
- **CarPlay**: `CPTemplateApplicationSceneDelegate` with tab bar (Home, Library, Recent), list templates and the
  shared Now Playing template. No video on the car display.

## Synchronisation model

| Data | Strategy |
| --- | --- |
| Likes, saved albums, follows, saved playlists | Offline queue → `/v1/me/library/sync`; server last-write-wins on device timestamps with removal tombstones; delta feed `/v1/me/library/changes` |
| Playlists | Row lock + `expectedVersion` optimistic concurrency; 409 with current version |
| Queue & position | `/v1/me/playback-state` compare-and-swap on `version` |
| Preferences | `/v1/me/preferences` compare-and-swap on `preferences_version` |
| Video progress | Last-write-wins on `updatedAt` |
| Play history | Idempotent events keyed by `clientEventId`; durable on-device outbox |

## Recommendations

`recommendations.service.ts` builds a taste vector (genres, moods, artists) from likes, follows, saved albums and
time-decayed plays, then scores catalog tracks with explicit weights (genre/artist affinity, popularity, freshness,
recently-played penalty) and limits per-artist runs. Every result carries human-readable reasons. It is rule-based —
not presented as AI — and sits behind a service boundary for a future learned model. Personalisation and history
can be switched off per user.
