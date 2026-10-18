# Architecture decision records

**ADR-001 — Name.** The product is STREAMERO (renamed from the working title SONARA). Bundle id placeholder
`com.example.streamero`, URL scheme `streamero://`.

**ADR-002 — NestJS 12 as ESM, Vitest + SWC.** NestJS 12 ships as ESM; the backend is ESM (`NodeNext`). Jest's ESM
support is brittle, so tests run on Vitest with `unplugin-swc` for decorator metadata.

**ADR-003 — SQL over an ORM.** Hand-written SQL via `pg` with shared projections keeps queries explicit, avoids
N+1 patterns, and lets us use PostgreSQL features (generated tsvector columns, trigram indexes, deferred
constraints, `FOR UPDATE`). Migrations are plain, checksummed SQL files.

**ADR-004 — Capability-aware renditions.** AVPlayer is not assumed to play every original. Lossy profiles are AAC
in MP4 (or the original when it is already compatible and within the bitrate cap); lossless is ALAC and exists only
for lossless sources. FLAC/WAV/AIFF originals are preserved but delivered as ALAC.

**ADR-005 — HLS in MPEG-TS with separate audio groups.** TS segments with aligned GOPs are the most compatible
target for AVPlayer and AirPlay; separate audio renditions enable language selection. WebVTT subtitles are added
to the master playlist at request time, so subtitles can be attached after transcoding without re-packaging.

**ADR-006 — Opaque path tokens for media.** Media URLs embed an AES-256-GCM sealed grant in the path: AVPlayer and
AirPlay receivers fetch without auth headers, HLS relative URLs inherit the grant, storage keys are hidden, and a
CDN can cache by path. Grants expire (default 6 h); the app re-resolves on failure.

**ADR-007 — Storage-agnostic object store.** A `StorageDriver` interface with local and S3 implementations.
Compose uses SeaweedFS because MinIO no longer publishes container images; any S3-compatible service works.
Uploads use S3 multipart so any API replica can accept any chunk.

**ADR-008 — Separate worker process.** FFmpeg runs only in the worker container (unprivileged, read-only root,
no capabilities, CPU/memory/pids limits). Inputs are restricted with `-format_whitelist` and
`-protocol_whitelist file`; arguments are passed without a shell.

**ADR-009 — Explainable recommendations first.** Weighted scoring over genre/mood/artist affinity, popularity and
freshness, with reasons shown to users. Not presented as AI. Candidate sampling (2,000 rows) bounds cost today;
a candidate-generation stage or learned model can replace `scoreTracks` behind the same API.

**ADR-010 — Sync semantics.** Library edits: offline queue + last-write-wins on device timestamps with tombstones.
Playlists, queue state and preferences: optimistic concurrency with versions and 409 responses carrying the
current state. Play events: idempotent client event ids.

**ADR-011 — iOS architecture.** SwiftUI + Observation, a composition root (`AppModel`) injected through the
environment, platform-independent logic in the `StreameroCore` package (Swift 6 strict concurrency, tested on Linux
and macOS). The app target uses Swift 5 language mode with minimal concurrency checking to interoperate with
AVFoundation delegate/KVO APIs; isolation is still explicit (`@MainActor`, `MainActor.assumeIsolated`).

**ADR-012 — XcodeGen.** `ios/project.yml` is the source of truth; the `.xcodeproj` is generated (no merge conflicts,
reviewable diffs). CI and the build scripts run `xcodegen generate`.

**ADR-013 — Unsigned IPA for sideloading.** The primary distribution path requested is Feather. CI builds with
`CODE_SIGNING_ALLOWED=NO` and packages `Payload/STREAMERO.app` into an IPA; the sideloading tool signs it with the
user's certificate. Entitlement-gated features (CarPlay, Sign in with Apple) depend on that certificate's profile.

**ADR-014 — Two-deck audio engine.** AVQueuePlayer gives gapless transitions when the next item is pre-queued.
Crossfade needs two simultaneously playing players, so a second deck plays the next track while volumes follow an
equal-power curve; the decks then swap.

**ADR-015 — YouTube boundary.** Discovery uses the official Data API; playback uses the official IFrame embed,
foreground only. The generic importer refuses YouTube/googlevideo hosts. No stream extraction or DRM circumvention.

**ADR-016 — Tokens in the admin dashboard.** Access token in memory, refresh token in `sessionStorage` (cleared when
the tab closes), strict CSP and `frame-ancestors 'none'` on the dashboard.
