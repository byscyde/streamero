# API

- Base path: `/v1`. Machine-readable spec: [`openapi.json`](openapi.json) (also served at `/openapi.json`, UI at `/docs`).
- Auth: `Authorization: Bearer <accessToken>`. Obtain via `POST /v1/auth/login|register|apple`; refresh with
  `POST /v1/auth/refresh { refreshToken }` (single-use; the response carries a new refresh token).
- Errors: `{ "error": { "code": "version_conflict", "message": "…", "details": { … } }, "requestId": "…" }`.
  Clients switch on `code`. Validation failures use `validation_failed` with field messages in `details`.
- Pagination: `?limit=` (1–100, default 30) and `?offset=`; responses are `{ items, limit, offset, total?, nextOffset }`.
- Compatibility: additive changes only within `/v1`; clients must ignore unknown fields. Breaking changes ship as `/v2`.

## Main resources

| Area | Endpoints |
| --- | --- |
| Auth | `POST /auth/register`, `/login`, `/refresh`, `/logout`, `/logout-all`, `/verify-email`, `/resend-verification`, `/forgot-password`, `/reset-password`, `/change-password`, `/apple` |
| Account | `GET/PATCH/DELETE /me`, `PUT /me/preferences` (versioned), `PUT/DELETE /me/avatar`, `GET /me/export`, `GET/DELETE /me/sessions[/:id]` |
| Catalog | `GET /home`, `/tracks?ids=`, `/tracks/:id`, `/tracks/:id/lyrics`, `/artists[/:id][/tracks]`, `/albums[/:id]`, `/videos[/:id]`, `/genres`, `/genres/:name/tracks`, `/moods/:name/tracks`, `/artwork/:id?size=small|large` (public) |
| Discovery | `GET /mixes`, `/mixes/:id`, `/recommendations/albums`, `/charts/trending` |
| Search | `GET /search?q=&types=tracks,artists,albums,playlists,videos,genres`, `/search/suggestions?q=`, `GET/POST/DELETE /me/recent-searches` |
| Library | `GET /me/library`, `/me/library/ids`, `/me/library/changes?since=`, `POST /me/library/sync`, `PUT/DELETE /me/{liked/tracks,albums,following/artists,liked/videos,saved/playlists}/:id`, list endpoints for each |
| Playlists | `POST /playlists`, `GET/PATCH/DELETE /playlists/:id`, `POST /playlists/:id/items`, `/items/remove`, `/items/move`, `/items/reorder`, collaborators, `GET /playlists/featured`, `GET /share/playlists/:token` (public) |
| Playback | `POST /me/playback/events` (idempotent), `GET /me/recently-played`, `/me/history`, `PUT /me/progress/videos/:id`, `PUT /me/progress/tracks/:id`, `GET/PUT /me/playback-state` (versioned) |
| Streaming | `GET /tracks/:id/stream?profile=data_saver|standard|high|lossless`, `GET /videos/:id/stream`, `GET /media/:token[/*path]` (signed, Range) |
| Downloads | `POST /me/downloads`, `GET /me/downloads`, `POST /me/downloads/validate`, `DELETE /me/downloads/:id` |
| YouTube | `GET /youtube/status`, `GET /youtube/search?q=` |
| Admin (editor+) | uploads (`POST /admin/uploads`, `PUT …/chunks/:i`, `POST …/complete`), imports (`/admin/imports/url`, `/admin/imports/path` admin-only), jobs, reprocess, tracks/albums/artists/videos/subtitles CRUD, bulk track actions, lyrics, home sections, storage, activity |
| Admin (admin) | users & roles, audit logs, system health, config |
| Health | `GET /healthz`, `/readyz`, `/metrics` (internal) |

### Example: play a track

```http
GET /v1/tracks/9d89…/stream?profile=lossless
Authorization: Bearer eyJ…

200 { "profile": "lossless", "url": "https://music.example.com/v1/media/<token>",
      "delivery": { "codec": "alac", "lossless": true, "sampleRate": 48000, "bitDepth": 24 },
      "source":   { "codec": "flac", "lossless": true }, "expiresAt": "…" }
```

If the source is lossy the response falls back (e.g. `"profile": "high", "delivery": { "codec": "aac", "lossless": false }`).
