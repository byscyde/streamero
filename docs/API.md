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
| App config | `GET /app/config` (public, `Cache-Control: public, max-age=30`, `ETag` = `version`, `If-None-Match` → 304); `GET /sync/state` returns `configVersion` |
| Admin (editor+) | uploads (`POST /admin/uploads`, `PUT …/chunks/:i`, `POST …/complete`), imports (`/admin/imports/url`, `/admin/imports/path` admin-only), jobs, reprocess, tracks/albums/artists/videos/subtitles CRUD, bulk track actions, lyrics, home sections, storage, activity, metadata lookup (`GET /admin/metadata/search?q=` → `{ items }`, `POST /admin/metadata/apply`) |
| Admin (admin) | users (`GET/POST /admin/users`, `GET/PATCH/DELETE /admin/users/:id`, `POST /admin/users/:id/password`, `POST /admin/users/:id/send-reset`), appearance (`GET/PUT /admin/appearance`, `POST /admin/appearance/reset`), audit logs, system health, config |
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

### App config, user management and metadata lookup

The binding contract is [`APP_CONFIG.md`](APP_CONFIG.md). Implementation notes:

- `PUT /admin/appearance` accepts a full or partial document; `version` and `defaults` in the body are ignored, any other
  unknown key is a `400 validation_failed` whose `details` are `[{ path: "theme.accent", message }]`. Returns the merged document.
  Stored values that stop validating after an upgrade are dropped field by field, so clients always get a valid document.
- Admin user endpoints return the user as listed by `GET /admin/users` (`id, email, displayName, role, disabled, emailVerified,
  createdAt, lastActiveAt, lastPlayedAt`). `POST /admin/users` → 201 (409 `email_taken`); without `password` (or with
  `sendInvite: true`) a set-password link valid for 3 days is emailed. `POST …/password` → 204 and revokes all sessions;
  `POST …/send-reset` → 202 (409 `account_disabled` for disabled accounts); `DELETE` → 204, 409 `cannot_delete_self` / `last_admin`.
- Email links use `APP_LINK_BASE` (default `https://app.streamero.net/`): `reset-password?token=…`, `verify-email?token=…`.
- Metadata: search results carry an extra `score` (MusicBrainz relevance 0–100); `503 metadata_unavailable` when MusicBrainz
  cannot be reached. `apply` returns the admin track plus `applied: { fields, cover: stored|kept|not_available|failed|skipped }`.
  Without `overwrite` only empty/placeholder values are filled (`Untitled`, `Unknown Artist`, no album or the auto-created
  single, no genres/track number/release date/artwork); with `overwrite: true` MusicBrainz values replace existing ones.
  `METADATA_AUTOFILL=true` makes the worker do this automatically after ingestion when confidence ≥ 90 %.
