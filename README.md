# Streamero

<img src="design/logo-mark.svg" width="96" alt="Streamero logo">

**One iPhone app to run the whole streamero.net media stack.** Developed by **[SCYDE](https://scyde.dev)**.

Streamero is a native SwiftUI admin app for a self-hosted Jellyfin server and the *arr apps around it. It talks
directly to each service's own API — there is no Streamero server in between.

| Service | Default address | What you can do in the app |
| --- | --- | --- |
| Jellyfin | `https://streamero.net` | Active streams (direct play / transcode, bitrate; pause, stop, message), libraries (scan, replace metadata, add/remove library and folders), recently added, users (create, delete, enable/disable, admin, password, **permissions, library access, stream and bitrate limits**), plugins (enable/disable, uninstall, install from catalog), devices, API keys, scheduled tasks, activity log, server log files, restart / shut down |
| Jellyseerr / Overseerr | `https://req.streamero.net` | Requests (approve, decline, delete, retry), discover & request, issues, **users and permissions**, import Jellyfin users, **jobs** (run / cancel) — several instances supported |
| Sonarr | `https://son.streamero.net` | Series, seasons and episodes, search, **interactive search** (season packs / single episodes, with rejection reasons), edit (quality profile, series type, season folders, monitored seasons, tags), add, delete |
| Radarr | `https://rad.streamero.net` | Movies, search, **interactive search**, edit (quality profile, minimum availability, tags), add, delete |
| Lidarr | `https://lid.streamero.net` | Artists and albums, search, interactive album search, edit (quality and metadata profile, tags), add, delete |
| Prowlarr | `https://prow.streamero.net` | Indexers (health, stats, enable/disable, test), apps, release search and grab, sync to apps |
| Bazarr | `https://baz.streamero.net` | Missing subtitles with one-tap download per language, **manual search** (all provider results with scores), history, providers, tasks |
| qBittorrent | `https://qbit.streamero.net` | Speeds, alternative speed limits, torrents by state, pause / resume / delete (with or without files) / recheck / reannounce, add magnet or URL |
| SABnzbd | `https://sab.streamero.net` | Queue and history, pause / resume (all or one), speed limit, delete, retry failed, add NZB URL |

**Settings and System for every *arr app (Manage)** — the same pages as their web UIs: download clients, indexers,
import lists, connections (notifications), metadata, Prowlarr apps and indexer proxies (all edited through the form
each app describes for itself: add from any implementation, edit every field, test, test all, enable/disable,
delete), quality profiles (upgrades), root folders, tags, status & health, scheduled tasks (run now), backups (create,
delete), updates (changelog, install), logs, blocklist, RSS sync, restart and shut down.

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
