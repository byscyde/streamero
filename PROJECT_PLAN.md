# STREAMERO project plan

Product: premium self-hosted music & video streaming — native iOS app, API + media workers, admin dashboard.
Tagline: *Your Sound. Your Screen. Your World.* Status per item: [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md).

## Assumptions
- Operators stream media they own or license; no third-party content is scraped or ripped.
- The app is distributed by sideloading (Feather/AltStore) first, with TestFlight/App Store as separate paths.
- One server per community/household/label; multi-tenant hosting is out of scope for v1.
- iOS 17 minimum (Observation, SwiftData, modern SwiftUI navigation); iPhone first, iPad supported.

## Phases
| # | Phase | State |
| --- | --- | --- |
| 1 | Inspect environment, architecture, repo structure, buildable baseline | ✅ |
| 2 | Backend foundations: schema, migrations, auth, API contracts, health | ✅ |
| 3 | Media storage, chunked uploads, FFprobe metadata, artwork, ingestion queue | ✅ |
| 4 | iOS design system, onboarding, auth, Home, Search, Library, Artist/Album/Playlist | ✅ (CI-built; device QA pending) |
| 5 | Audio engine, persistent queue, lock screen, background playback, recovery | ✅ (device QA pending) |
| 6 | Video: HLS, quality, subtitles, progress, PiP, collections | ✅ (device QA pending) |
| 7 | Offline downloads, library sync, favourites, playlists, history | ✅ |
| 8 | CarPlay templates + entitlement documentation | ✅ code / ⛔ entitlement |
| 9 | Admin dashboard: catalog, users, jobs, monitoring | ✅ |
| 10 | Recommendations, search, performance | ✅ rule-based recs, PostgreSQL FTS |
| 11 | Security review, tests, backup verification, deployment docs | ✅ (device tests pending) |
| 12 | Release build + IPA | ✅ unsigned IPA in CI / ⛔ signed IPA needs Apple signing assets |

## Next steps
1. Physical-device QA (checklist in IMPLEMENTATION_STATUS.md).
2. Request the CarPlay audio entitlement; create the Google OAuth client IDs.
3. Word-level lyric highlighting, timeline-preview thumbnails while scrubbing, collaborator invite UI.
4. Loudness normalisation (EBU R128 analysis in the worker + per-track gain in the player).
5. Candidate generation for recommendations at large catalog sizes; optional OpenSearch backend.
