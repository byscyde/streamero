# STREAMERO

**Your Sound. Your Screen. Your World.**

STREAMERO is a self-hosted, premium music and video streaming platform: a native SwiftUI iPhone/iPad app
with background audio and CarPlay, a NestJS API with an FFmpeg media pipeline, and a web admin dashboard.

| Part | Path | Stack |
| --- | --- | --- |
| iOS app | [`ios/`](ios) | Swift, SwiftUI, AVFoundation/AVKit, MediaPlayer, CarPlay, SwiftData — iOS 17+ |
| Shared Swift core | [`ios/Packages/StreameroCore`](ios/Packages/StreameroCore) | Platform-independent models, API client, queue, lyrics/subtitle parsing (tested on Linux too) |
| API + media worker | [`backend/`](backend) | TypeScript, NestJS 12, PostgreSQL 16, Redis + BullMQ, S3-compatible storage, FFmpeg/FFprobe, HLS |
| Admin dashboard | [`admin/`](admin) | React 19, Vite, TypeScript |
| Infrastructure | [`docker-compose.yml`](docker-compose.yml), [`infra/`](infra) | Docker Compose, nginx, SeaweedFS (S3) |
| Docs | [`docs/`](docs) | Architecture, API, deployment, iOS build/IPA, CarPlay, security, backups, testing |

## Install the iPhone app with Feather (or another sideloading tool)

The CI builds an **unsigned** `STREAMERO-<version>-<build>-unsigned.ipa` on every push
([`.github/workflows/ios.yml`](.github/workflows/ios.yml)). An unsigned IPA cannot be installed on an
iPhone as-is — Feather (or AltStore, SideStore, Sideloadly, ESign) signs it with **your own** certificate
and provisioning profile during installation.

1. Download **`STREAMERO.ipa`** from [GitHub Releases](https://github.com/mmzlopasa/streamero/releases)
   (every `v*` tag publishes one; branch builds are also available as Actions artifacts).
2. In Feather: *Library › Import* the `.ipa`, choose your certificate, sign, and install.
3. Launch STREAMERO and sign in. The app connects to **`https://app.streamero.net`** automatically
   (compiled in via `STREAMERO_SERVER_URL`; users never see or enter it) and syncs library changes and new
   content every 30 seconds while it is open.

What works when re-signed with a normal (non-entitled) certificate: everything except **CarPlay** and
**Sign in with Apple**, which need entitlements only Apple can grant to your team
(see [`docs/CARPLAY.md`](docs/CARPLAY.md)). Background audio, lock-screen controls, AirPlay, Picture in
Picture and downloads need no special entitlement. Full details: [`docs/IOS_BUILD.md`](docs/IOS_BUILD.md).

## Run the server

🇭🇷 **Upute na hrvatskom, korak po korak (uključujući postojeći nginx):** [`docs/INSTALACIJA_SERVERA.md`](docs/INSTALACIJA_SERVERA.md) — ili samo `sudo ./scripts/install-server.sh`.

```bash
cp .env.example .env            # set POSTGRES_PASSWORD, S3_SECRET_KEY, JWT_ACCESS_SECRET,
                                # MEDIA_SIGNING_SECRET, BOOTSTRAP_ADMIN_PASSWORD (openssl rand -base64 48)
docker compose up -d --build
open http://localhost:8088/admin/   # sign in as BOOTSTRAP_ADMIN_EMAIL, upload music and videos
```

Only nginx publishes a port; PostgreSQL, Redis and object storage live on an internal network.
API docs are served at `/docs` (Swagger UI) and `docs/openapi.json`. Production setup (TLS, external
S3, SMTP, scaling, monitoring): [`docs/DEPLOYMENT.md`](docs/DEPLOYMENT.md).

## Develop

```bash
# backend (needs PostgreSQL 16, Redis 7, FFmpeg)
cd backend && cp .env.example .env && npm ci && npm run build && npm start   # API on :8080
node --env-file=.env dist/worker.js                                          # media worker
npm test                                                                     # unit + integration tests

# admin
cd admin && npm ci && npm run dev        # http://localhost:5173/admin/ (proxies /v1 to :8080)

# Swift core (macOS or Linux)
swift test --package-path ios/Packages/StreameroCore

# iOS app (macOS + Xcode 16+)
brew install xcodegen && cd ios && xcodegen generate && open STREAMERO.xcodeproj
```

## Project documents

- [PROJECT_PLAN.md](PROJECT_PLAN.md) — phases and checklist
- [ARCHITECTURE.md](ARCHITECTURE.md) — system design
- [IMPLEMENTATION_STATUS.md](IMPLEMENTATION_STATUS.md) — what is done, partial, or blocked (honest list)
- [DECISIONS.md](DECISIONS.md) — architecture decision records
- [SECURITY.md](SECURITY.md) — threat model and controls
- [docs/](docs) — API, deployment, backups, iOS build & IPA, CarPlay, media formats, testing, release checklist

## Content policy

STREAMERO streams media the operator owns or is licensed to distribute. The importer only accepts files
from allow-listed sources with a recorded authorisation note. YouTube is supported only through the official
Data API (discovery) and the official embedded player; STREAMERO never downloads, extracts or proxies
YouTube streams and does not circumvent DRM.
