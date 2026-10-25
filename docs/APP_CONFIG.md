# Remote app configuration, user management and metadata lookup (API contract)

This is the shared contract between the backend, the admin dashboard, the web player (`web/`) and the
iOS app. Field names are exact; all colours are `#RRGGBB` strings.

## 1. Appearance / remote config

Stored server-side as one JSON document (table `app_settings`, key `appearance`). Every field is optional
in storage; the server always **returns the full document merged over the defaults below**, so clients can
rely on every field being present.

```jsonc
{
  "version": "3f9a1c0b2d4e5f60",        // opaque; changes whenever the document changes
  "brand": {
    "appName": "STREAMERO",
    "tagline": "Your Sound. Your Screen. Your World.",
    "developer": "SCYDE",
    "developerUrl": "https://scyde.dev",
    "supportEmail": "no-reply@scyde.dev"
  },
  "theme": {
    "accent": "#E31E2D",                 // primary buttons, active states, progress
    "onAccent": "#FFFFFF",               // text/icons on accent
    "background": "#0E0E10",
    "surface": "#18181B",                // cards, rows, mini player
    "surfaceRaised": "#232327",          // inputs, chips, sheets
    "border": "#3A3A40",                 // outline pills ("More", Shuffle, Radio)
    "textPrimary": "#FFFFFF",
    "textSecondary": "#A1A1AA",
    "titleFont": "mono",                 // "mono" | "default" | "rounded" — track/album/artist titles
    "cornerRadius": 12,                  // 0..28, cards & artwork (pills stay fully rounded)
    "genreGradients": true,              // colourful gradient genre chips vs. plain chips
    "playerStyle": "artwork"             // "artwork" (tint from cover art) | "solid"
  },
  "texts": {
    "welcomeTitle": "Discover your music,\npersonalize your experience",
    "welcomeSubtitle": "Use your email or Apple ID to continue with STREAMERO.",
    "homeGreeting": true                 // "Good morning, <name>" header on Home
  },
  "home": {
    "chips": ["All", "Music", "Videos"],  // subset/order of: All, Music, Videos
    "sectionsOrder": ["recommended_playlists", "genres", "top_artists", "new_albums", "popular_singles",
                       "recently_played", "made_for_you", "music_videos"]
  },
  "features": {
    "videos": true, "youtube": true, "lyrics": true, "downloads": true,
    "equalizer": true, "radio": true, "signup": true, "appleSignIn": true
  },
  "announcement": { "enabled": false, "text": "", "style": "info" }   // style: info | warning | success
}
```

`home.sectionsOrder` ids map onto `GET /v1/home` section kinds (identically in web and iOS):
`recommended_playlists` → featured_playlists, editorial · `genres` → genres, moods · `top_artists` →
favorite_artists · `new_albums` → recently_added, album_recommendations · `popular_singles` → trending ·
`recently_played` → continue_listening, recently_played · `made_for_you` → made_for_you ·
`music_videos` → music_videos, continue_watching. Unmapped kinds keep server order after the listed ones.

Endpoints:

| Method & path | Auth | Purpose |
| --- | --- | --- |
| `GET /v1/app/config` | none (public, cacheable 30 s, `ETag` = version) | Full merged config. Used before login (welcome screen) too. |
| `GET /v1/admin/appearance` | admin | Same as above plus `"defaults"` (the default document) |
| `PUT /v1/admin/appearance` | admin | Body = full or partial document (without `version`); validated (zod, strict colours/enums/lengths); stored; audited; returns the merged document |
| `POST /v1/admin/appearance/reset` | admin | Restore defaults |

Propagation: `GET /v1/sync/state` gains `"configVersion"`. Clients poll sync state every 30 s and refetch
`/v1/app/config` when `configVersion` changes, so admin edits appear in open apps within ~30 s
(the web player also refetches on window focus).

## 2. User management (admin)

| Method & path | Purpose |
| --- | --- |
| `GET /v1/admin/users?q=&role=&limit=&offset=` | existing list (`id, email, displayName, role, disabled, emailVerified, createdAt, lastActiveAt`) |
| `POST /v1/admin/users` | `{ email, displayName, role: user|editor|admin, password?, sendInvite?: boolean }` → creates account (email verified = true when created by admin). If no password is given, a reset email is sent so the user sets one. 409 on duplicate email. |
| `PATCH /v1/admin/users/:id` | existing + `email`, `displayName`, `emailVerified` (plus `role`, `disabled`) |
| `POST /v1/admin/users/:id/password` | `{ password }` → sets a new password (policy: ≥ 10 chars, letters + digits), revokes all of that user's sessions |
| `POST /v1/admin/users/:id/send-reset` | emails a password-reset link to the user |
| `DELETE /v1/admin/users/:id` | permanently deletes the account and its personal data (same path as self-service deletion). Admins cannot delete themselves or the last active admin. |

All actions write audit-log entries. Self-service (existing): `POST /v1/auth/change-password`
`{ currentPassword, newPassword }`, `POST /v1/auth/forgot-password`, `POST /v1/auth/reset-password`.

Email links (`APP_LINK_BASE`, default `https://app.streamero.net/`) open the **web player**:
`/reset-password?token=…` and `/verify-email?token=…`. Sender: `MAIL_FROM="STREAMERO <no-reply@scyde.dev>"`.

## 3. Metadata lookup (replaces any "grabber")

STREAMERO does not download audio from YouTube or other streaming sites (that would break their terms
and copyright). Instead, metadata for files you own is filled in from **MusicBrainz** + **Cover Art Archive**
(free, official APIs):

| Method & path | Purpose |
| --- | --- |
| `GET /v1/admin/metadata/search?q=<artist and/or title>` | editor+. Returns up to 25 recordings: `{ id (MBID), title, artist, album, albumId, year, durationMs, genres[], coverUrl }` |
| `POST /v1/admin/metadata/apply` | `{ trackId, recordingId, releaseId?, overwrite?: boolean }` → fills title/artist/album/year/genres/track number and downloads the cover art; returns the updated track |

Automatic mode: env `METADATA_AUTOFILL=true` makes the worker look up tracks whose tags are missing
artist/album/genre/artwork after ingestion (best match, only when confidence ≥ 90 %).
YouTube remains discovery-only via the official Data API + embedded player.
