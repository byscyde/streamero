# Streamero

<img src="design/logo-mark.svg" width="96" alt="Streamero logo">

**One iPhone app to run the whole streamero.net media stack.** Developed by **[SCYDE](https://scyde.dev)**.

Streamero is a native SwiftUI admin app for a self-hosted Jellyfin server and the *arr apps around it. It talks
directly to each service's own API — there is no Streamero server in between.

| Service | Default address | What you can do in the app |
| --- | --- | --- |
| Jellyfin | `https://streamero.net` | See who is watching (direct play / transcode, bitrate), pause/stop/message a stream, scan libraries, recently added, manage users (create, delete, enable/disable, admin, password), run scheduled tasks, activity log, restart / shut down |
| Jellyseerr / Overseerr | `https://req.streamero.net` | Pending/approved/available requests, approve, decline, delete, retry, discover & request movies/series, issues (resolve) — several Seerr instances supported |
| Sonarr | `https://son.streamero.net` | Series library, seasons & episodes, search series/season/episode, monitor, refresh, delete, add new series |
| Radarr | `https://rad.streamero.net` | Movie library, file & quality, search, monitor, refresh, delete, add new movies |
| Lidarr | `https://lid.streamero.net` | Artists & albums, album/artist search, monitor, delete, add new artists |
| Prowlarr | `https://prow.streamero.net` | Indexers with health and stats, enable/disable, test, sync to apps, manual release search and grab |
| Bazarr | `https://baz.streamero.net` | Missing subtitles per episode/movie with one-tap download per language, history, provider status/reset, tasks |

Across services: a **dashboard** (status and version of every service, health warnings, active streams, pending
requests, downloads, disk space, what's airing in the next 7 days, auto-refresh every 30 s), a combined **download
queue** (remove / blocklist), **calendar**, **wanted** (missing) lists with search, and **history**.

All addresses are editable. API keys are stored only in the iPhone Keychain, and the app can be locked with Face ID.

## Install (Feather)

1. Download **`STREAMERO.ipa`** from [Releases](https://github.com/mmzlopasa/streamero/releases).
2. In Feather: import the IPA, sign it with your certificate, install.
3. Open Streamero and enter the API key of each service (see [`docs/POSTAVLJANJE.md`](docs/POSTAVLJANJE.md)).

The IPA is unsigned; Feather (or AltStore, SideStore, Sideloadly) signs it. No special entitlements are needed.

## Repository

| Path | |
| --- | --- |
| [`ios/STREAMERO`](ios/STREAMERO) | SwiftUI app (iOS 17+) |
| [`ios/Packages/StreameroKit`](ios/Packages/StreameroKit) | API clients and models for all services, tested on Linux with recorded responses |
| [`scripts/build-unsigned-ipa.sh`](scripts/build-unsigned-ipa.sh) | Builds the unsigned IPA (macOS + Xcode) |
| [`.github/workflows`](.github/workflows) | CI (Linux tests, simulator tests, IPA) and releases from the `VERSION` file |

```bash
swift test --package-path ios/Packages/StreameroKit          # macOS or Linux
brew install xcodegen && cd ios && xcodegen generate && open STREAMERO.xcodeproj
```

Version 1.x (the earlier music streaming app) is preserved in the `v1.3.3` tag and its release.
