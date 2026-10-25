# STREAMERO web player

Browser version of STREAMERO (React 19 + Vite + TypeScript), served at the site root
(`https://app.streamero.net/`) by the same nginx container that serves `/admin/` and proxies `/v1/`.

```bash
npm install
npm run dev        # http://localhost:5174, proxies /v1 to $STREAMERO_API (default http://localhost:8080)
npm run build      # type-check + production bundle in dist/
npm test           # vitest unit tests (src/**/*.test.ts)
```

`VITE_API_BASE` can point the build at an API on another origin; by default the player talks to its own
origin, and absolute API URLs (artwork, media) are rewritten to same-origin paths so the strict CSP holds.

## Structure

| Path | What |
| --- | --- |
| `src/lib/api.ts` | API client: access token in memory, rotating refresh token, one shared refresh, 401 → refresh → retry once |
| `src/lib/appearance.ts` | Remote appearance config (`GET /v1/app/config`) → CSS variables, Home section order/filters |
| `src/lib/eq.ts` | 10-band EQ bands, presets, preamp/headroom math, persistence |
| `src/lib/queue.ts` | Pure queue state machine (shuffle, repeat, play next, reorder) — port of the iOS `PlaybackQueue` |
| `src/lib/lyrics.ts` | Synced lyrics timeline + LRC parser — port of the iOS `LyricsTimeline` |
| `src/player/engine.ts` | Two `<audio>` elements (current + preloaded next) → Web Audio: preamp → 10 `BiquadFilterNode`s → analyser |
| `src/player/player.ts` | Player controller: queue, stream URLs, playback events/progress, cross-device playback state, Media Session |
| `src/state/app.ts` | Auth, config, library ids, `/v1/sync/state` polling (30 s while visible + on focus) |
| `src/pages/*` | Welcome/auth, Home, Search, Explore, Library, Album/Artist/Playlist/Mix/Genre, Video (hls.js), Settings |

## Token storage (trade-off)

- **Access token** (15 min): memory only — never written to storage, never logged.
- **Refresh token** (rotating, single-use): `localStorage` (`streamero.web.refresh`) so a reload or a new tab
  stays signed in. Anything running on the origin can read `localStorage`, so an XSS bug could steal it.
  Mitigations: strict CSP (`script-src` falls back to `'self'`, no inline or third-party scripts), rotation
  on every refresh and server-side reuse detection (presenting an already-rotated token revokes the whole
  session family), "Sign out everywhere" and per-session revocation in Settings.
- The stronger option — an `HttpOnly; Secure; SameSite=Strict` refresh cookie — needs a cookie-based
  refresh endpoint in the API, which doesn't exist yet.
- Because the server revokes on reuse, tabs must not refresh concurrently: refreshes are serialised with the
  Web Locks API (`navigator.locks`) and the stored token is re-read inside the lock; if another tab rotated it
  meanwhile, the newer token is used instead of signing out. Signing out in one tab signs out the others
  (`storage` event).

## Notes

- Audio: the API delivers AAC (and ALAC for "Lossless"). Chrome/Firefox can't decode ALAC, so the player
  checks `canPlayType('audio/mp4; codecs="alac"')` and falls back to "High" automatically.
- The equalizer runs in Web Audio. Media is same-origin; if a media URL is cross-origin the element gets
  `crossOrigin="anonymous"` (the server must then send CORS headers, or the EQ output would be silent).
- Video uses native HLS on Safari and hls.js elsewhere (worker disabled because the CSP has no `blob:` workers).
- Keyboard: Space/K play-pause · ←/→ seek 5 s · Shift+←/→ previous/next · ↑/↓ volume · M mute · S shuffle ·
  R repeat · L lyrics · Q queue.
