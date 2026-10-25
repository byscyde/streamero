/**
 * STREAMERO API client for the web player.
 *
 * Token storage trade-off (documented in web/README.md):
 *  - The short-lived access token (15 min) lives in memory only, so it never touches storage.
 *  - The rotating, single-use refresh token is kept in localStorage so a reload or a new tab keeps the
 *    user signed in. localStorage is readable by any script on the origin, so an XSS bug could steal it;
 *    we mitigate with a strict CSP (no inline/third-party scripts), rotation on every use and server-side
 *    reuse detection (a replayed token revokes the whole session family). The API has no cookie-based
 *    refresh endpoint, which would be the stronger option (HttpOnly cookie).
 *  - Because the server revokes the family when a rotated token is presented twice, refreshes are
 *    serialised across tabs with the Web Locks API and the token is re-read inside the lock.
 * Tokens are never logged.
 */
import type {
  Album, AlbumPage, Artist, ArtistPage, DeviceSession, GenreInfo, HistoryEntry, HomeFeed, LibraryIds, LyricsResponse,
  Mix, MixDetail, Page, PlaybackEvent, Playlist, PlaylistPage, SearchResponse, Session, StreamProfile, SyncState, Track,
  TrackStream, User, Video, VideoPage, VideoStream, YouTubeResult, LibraryItemType,
} from './types';
import type { AppConfig } from './appearance';

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = 'ApiError';
  }
  get isNetwork() {
    return this.status === 0;
  }
  get isSessionExpired() {
    return this.code === 'session_expired';
  }
}

export interface TokenStorage {
  get(): string | null;
  set(value: string | null): void;
}

export const REFRESH_KEY = 'streamero.web.refresh';

export const localTokenStorage: TokenStorage = {
  get() {
    try {
      return localStorage.getItem(REFRESH_KEY);
    } catch {
      return null;
    }
  },
  set(v) {
    try {
      if (v) localStorage.setItem(REFRESH_KEY, v);
      else localStorage.removeItem(REFRESH_KEY);
    } catch {
      /* storage unavailable (private mode): session lasts for this tab only */
    }
  },
};

type LockFn = <T>(name: string, fn: () => Promise<T>) => Promise<T>;

/** Cross-tab mutual exclusion (Web Locks). Falls back to running directly where unsupported. */
export const webLock: LockFn = (name, fn) => {
  const locks = typeof navigator !== 'undefined' ? (navigator as Navigator & { locks?: LockManager }).locks : undefined;
  if (locks?.request) return locks.request(name, () => fn()) as Promise<Awaited<ReturnType<typeof fn>>>;
  return fn();
};

export interface RequestOptions {
  body?: unknown;
  query?: Record<string, string | number | boolean | undefined | null>;
  auth?: boolean;
  signal?: AbortSignal;
  /** Lets the request outlive the page (used for reports sent on pagehide). */
  keepalive?: boolean;
}

export interface ClientOptions {
  baseUrl?: string;
  fetch?: typeof fetch;
  storage?: TokenStorage;
  lock?: LockFn;
  now?: () => number;
  deviceName?: string;
}

export class ApiClient {
  readonly baseUrl: string;
  private readonly fetchFn: typeof fetch;
  private readonly storage: TokenStorage;
  private readonly lock: LockFn;
  private readonly now: () => number;
  private readonly deviceName: string;
  private access: { token: string; expiresAt: number } | null = null;
  private refreshing: Promise<void> | null = null;
  onSessionExpired: () => void = () => {};

  constructor(opts: ClientOptions = {}) {
    this.baseUrl = (opts.baseUrl ?? '').replace(/\/$/, '');
    this.fetchFn = opts.fetch ?? ((...a) => globalThis.fetch(...a));
    this.storage = opts.storage ?? localTokenStorage;
    this.lock = opts.lock ?? webLock;
    this.now = opts.now ?? (() => Date.now());
    this.deviceName = opts.deviceName ?? 'STREAMERO Web';
  }

  get hasSession() {
    return !!this.storage.get();
  }

  /** Stores a fresh session (login/register). */
  setSession(s: Pick<Session, 'accessToken' | 'refreshToken' | 'expiresIn'>) {
    this.access = { token: s.accessToken, expiresAt: this.now() + s.expiresIn * 1000 };
    this.storage.set(s.refreshToken);
  }

  clearSession() {
    this.access = null;
    this.storage.set(null);
  }

  url(path: string, query?: RequestOptions['query']) {
    let u = this.baseUrl + path;
    if (query) {
      const p = new URLSearchParams();
      for (const [k, v] of Object.entries(query)) if (v !== undefined && v !== null && v !== '') p.set(k, String(v));
      const s = p.toString();
      if (s) u += (u.includes('?') ? '&' : '?') + s;
    }
    return u;
  }

  private async perform(method: string, path: string, o: RequestOptions, token: string | null): Promise<Response> {
    const headers: Record<string, string> = { accept: 'application/json' };
    let body: BodyInit | undefined;
    if (o.body instanceof FormData) body = o.body;
    else if (o.body !== undefined) {
      headers['content-type'] = 'application/json';
      body = JSON.stringify(o.body);
    }
    if (token) headers.authorization = `Bearer ${token}`;
    try {
      return await this.fetchFn(this.url(path, o.query), { method, headers, body, signal: o.signal, ...(o.keepalive ? { keepalive: true } : {}) });
    } catch (e) {
      if ((e as Error)?.name === 'AbortError') throw e;
      throw new ApiError(0, 'network', 'You appear to be offline. Check your connection and try again.');
    }
  }

  private async decode<T>(res: Response): Promise<T> {
    if (!res.ok) {
      let env: { error?: { code?: string; message?: string; details?: unknown } } | null = null;
      try {
        env = await res.json();
      } catch {
        /* non-JSON error */
      }
      const e = env?.error;
      throw new ApiError(res.status, e?.code ?? `http_${res.status}`, e?.message ?? `Request failed (${res.status})`, e?.details);
    }
    if (res.status === 204) return undefined as T;
    const text = await res.text();
    return (text ? JSON.parse(text) : undefined) as T;
  }

  /** Access token valid for at least 30 s, refreshing first if needed. */
  private async validToken(): Promise<string> {
    if (this.access && this.access.expiresAt - this.now() > 30_000) return this.access.token;
    await this.refresh();
    if (!this.access) throw new ApiError(401, 'session_expired', 'Your session has ended. Please sign in again.');
    return this.access.token;
  }

  /** One refresh at a time per tab (shared promise) and across tabs (Web Lock). */
  refresh(): Promise<void> {
    if (this.refreshing) return this.refreshing;
    const before = this.access?.token;
    this.refreshing = this.lock('streamero-refresh', async () => {
      // Another request in this tab may have refreshed while we waited for the lock.
      if (this.access && this.access.token !== before && this.access.expiresAt - this.now() > 30_000) return;
      const rt = this.storage.get();
      if (!rt) {
        this.expire();
        throw new ApiError(401, 'session_expired', 'Your session has ended. Please sign in again.');
      }
      const res = await this.perform('POST', '/v1/auth/refresh', { body: { refreshToken: rt } }, null);
      if (res.status === 401 || res.status === 403) {
        // Only a definitive rejection ends the session. If another tab rotated the token meanwhile,
        // the stored value differs from ours: retry with it instead of signing out.
        const latest = this.storage.get();
        if (latest && latest !== rt) {
          const again = await this.perform('POST', '/v1/auth/refresh', { body: { refreshToken: latest } }, null);
          if (again.ok) {
            this.setSession(await again.json());
            return;
          }
        }
        this.expire();
        throw new ApiError(401, 'session_expired', 'Your session has ended. Please sign in again.');
      }
      const s = await this.decode<Session>(res);
      this.setSession(s);
    }).finally(() => {
      this.refreshing = null;
    });
    return this.refreshing;
  }

  private expire() {
    const had = !!this.storage.get() || !!this.access;
    this.clearSession();
    if (had) this.onSessionExpired();
  }

  /** Sends a request; authenticated requests get a fresh token and one retry after a 401. */
  async request<T>(method: string, path: string, o: RequestOptions = {}): Promise<T> {
    if (o.auth === false) return this.decode<T>(await this.perform(method, path, o, null));
    const token = await this.validToken();
    const res = await this.perform(method, path, o, token);
    if (res.status === 401) {
      this.access = null;
      await this.refresh();
      return this.decode<T>(await this.perform(method, path, o, this.access!.token));
    }
    return this.decode<T>(res);
  }

  get<T>(path: string, query?: RequestOptions['query'], signal?: AbortSignal) {
    return this.request<T>('GET', path, { query, signal });
  }

  // ---- Auth --------------------------------------------------------------------------------------
  async login(email: string, password: string) {
    const s = await this.request<Session>('POST', '/v1/auth/login', { body: { email, password, deviceName: this.deviceName }, auth: false });
    this.setSession(s);
    return s.user;
  }
  async register(email: string, password: string, displayName: string) {
    const s = await this.request<Session>('POST', '/v1/auth/register', { body: { email, password, displayName }, auth: false });
    this.setSession(s);
    return s.user;
  }
  async logout() {
    const rt = this.storage.get();
    this.clearSession();
    if (rt) await this.request('POST', '/v1/auth/logout', { body: { refreshToken: rt }, auth: false }).catch(() => undefined);
  }
  async logoutAll() {
    await this.request('POST', '/v1/auth/logout-all');
    this.clearSession();
  }
  forgotPassword = (email: string) => this.request<void>('POST', '/v1/auth/forgot-password', { body: { email }, auth: false });
  resetPassword = (token: string, password: string) =>
    this.request<void>('POST', '/v1/auth/reset-password', { body: { token, password }, auth: false });
  verifyEmail = (token: string) => this.request<void>('POST', '/v1/auth/verify-email', { body: { token }, auth: false });
  resendVerification = () => this.request<void>('POST', '/v1/auth/resend-verification');
  changePassword = (currentPassword: string, newPassword: string) =>
    this.request<void>('POST', '/v1/auth/change-password', { body: { currentPassword, newPassword } });

  // ---- Account -----------------------------------------------------------------------------------
  me = () => this.get<User>('/v1/me');
  updateProfile = (patch: Partial<Pick<User, 'displayName' | 'allowExplicit' | 'historyEnabled' | 'personalizationEnabled'>>) =>
    this.request<User>('PATCH', '/v1/me', { body: patch });
  putPreferences = (preferences: Record<string, unknown>, baseVersion: number) =>
    this.request<{ preferences: Record<string, unknown>; version: number }>('PUT', '/v1/me/preferences', { body: { preferences, baseVersion } });
  uploadAvatar = (file: Blob) => {
    const fd = new FormData();
    fd.append('file', file);
    return this.request<User>('PUT', '/v1/me/avatar', { body: fd });
  };
  removeAvatar = () => this.request<void>('DELETE', '/v1/me/avatar');
  sessions = () => this.get<{ items: DeviceSession[] }>('/v1/me/sessions');
  revokeSession = (id: string) => this.request<void>('DELETE', `/v1/me/sessions/${enc(id)}`);
  exportData = () => this.get<unknown>('/v1/me/export');
  async deleteAccount(password?: string) {
    await this.request<void>('DELETE', '/v1/me', { body: password ? { password } : {} });
    this.clearSession();
  }

  // ---- App config & sync -------------------------------------------------------------------------
  appConfig = () => this.request<AppConfig>('GET', '/v1/app/config', { auth: false });
  syncState = () => this.get<SyncState>('/v1/sync/state');

  // ---- Catalog -----------------------------------------------------------------------------------
  home = () => this.get<HomeFeed>('/v1/home');
  track = (id: string) => this.get<Track>(`/v1/tracks/${enc(id)}`);
  lyrics = (id: string) => this.get<LyricsResponse>(`/v1/tracks/${enc(id)}/lyrics`);
  artists = (limit = 30, offset = 0) => this.get<Page<Artist>>('/v1/artists', { limit, offset });
  artist = (id: string) => this.get<ArtistPage>(`/v1/artists/${enc(id)}`);
  artistTracks = (id: string, limit = 50, offset = 0) => this.get<Page<Track>>(`/v1/artists/${enc(id)}/tracks`, { limit, offset });
  albums = (limit = 30, offset = 0, sort?: 'recent' | 'title') => this.get<Page<Album>>('/v1/albums', { limit, offset, sort });
  album = (id: string) => this.get<AlbumPage>(`/v1/albums/${enc(id)}`);
  videos = (limit = 30, offset = 0, genre?: string) => this.get<Page<Video>>('/v1/videos', { limit, offset, genre });
  video = (id: string) => this.get<VideoPage>(`/v1/videos/${enc(id)}`);
  genres = () => this.get<{ genres: GenreInfo[]; moods: GenreInfo[] }>('/v1/genres');
  tagTracks = (kind: 'genre' | 'mood', name: string, limit = 50, offset = 0) =>
    this.get<Page<Track>>(`/v1/${kind === 'mood' ? 'moods' : 'genres'}/${enc(name)}/tracks`, { limit, offset });
  mixes = () => this.get<{ items: Mix[] }>('/v1/mixes');
  mix = (id: string) => this.get<MixDetail>(`/v1/mixes/${enc(id)}`);
  recommendedAlbums = () => this.get<{ items: Album[] }>('/v1/recommendations/albums');
  trending = () => this.get<{ items: Track[] }>('/v1/charts/trending');
  featuredPlaylists = () => this.get<Page<Playlist>>('/v1/playlists/featured');

  // ---- Search ------------------------------------------------------------------------------------
  search = (q: string, types?: string[], limit = 20, signal?: AbortSignal) =>
    this.get<SearchResponse>('/v1/search', { q, types: types?.join(','), limit }, signal);
  recentSearches = () => this.get<{ items: { query: string }[] }>('/v1/me/recent-searches');
  addRecentSearch = (query: string) => this.request<void>('POST', '/v1/me/recent-searches', { body: { query } });
  clearRecentSearches = () => this.request<void>('DELETE', '/v1/me/recent-searches');
  youtubeStatus = () => this.get<{ enabled: boolean }>('/v1/youtube/status');
  youtubeSearch = (q: string) => this.get<{ items: YouTubeResult[]; attribution?: string }>('/v1/youtube/search', { q });

  // ---- Library -----------------------------------------------------------------------------------
  libraryIds = () => this.get<LibraryIds>('/v1/me/library/ids');
  likedTracks = (limit = 100, offset = 0) => this.get<Page<Track>>('/v1/me/liked/tracks', { limit, offset, sort: 'recent' });
  savedAlbums = (limit = 100, offset = 0) => this.get<Page<Album>>('/v1/me/albums', { limit, offset, sort: 'recent' });
  followedArtists = (limit = 100, offset = 0) => this.get<Page<Artist>>('/v1/me/following/artists', { limit, offset, sort: 'title' });
  likedVideos = (limit = 100, offset = 0) => this.get<Page<Video>>('/v1/me/liked/videos', { limit, offset });
  myPlaylists = (limit = 100, offset = 0) => this.get<Page<Playlist>>('/v1/me/playlists', { limit, offset, sort: 'recent' });
  setSaved(type: LibraryItemType, id: string, saved: boolean) {
    const path = { track: 'liked/tracks', album: 'albums', artist: 'following/artists', video: 'liked/videos', playlist: 'saved/playlists' }[type];
    return this.request<void>(saved ? 'PUT' : 'DELETE', `/v1/me/${path}/${enc(id)}`);
  }

  // ---- Playlists ---------------------------------------------------------------------------------
  playlist = (id: string, limit = 100, offset = 0) => this.get<PlaylistPage>(`/v1/playlists/${enc(id)}`, { limit, offset });
  createPlaylist = (title: string, description?: string) =>
    this.request<PlaylistPage>('POST', '/v1/playlists', { body: { title, visibility: 'private', ...(description ? { description } : {}) } });
  updatePlaylist = (id: string, patch: { title?: string; description?: string; visibility?: string; expectedVersion?: number }) =>
    this.request<PlaylistPage>('PATCH', `/v1/playlists/${enc(id)}`, { body: patch });
  deletePlaylist = (id: string) => this.request<void>('DELETE', `/v1/playlists/${enc(id)}`);
  addToPlaylist = (id: string, trackIds: string[], videoIds: string[] = []) =>
    this.request<PlaylistPage>('POST', `/v1/playlists/${enc(id)}/items`, { body: { trackIds, videoIds } });
  removeFromPlaylist = (id: string, itemIds: string[], expectedVersion?: number) =>
    this.request<PlaylistPage>('POST', `/v1/playlists/${enc(id)}/items/remove`, { body: { itemIds, expectedVersion } });
  reorderPlaylist = (id: string, itemIds: string[], expectedVersion?: number) =>
    this.request<PlaylistPage>('POST', `/v1/playlists/${enc(id)}/items/reorder`, { body: { itemIds, expectedVersion } });

  // ---- Playback ----------------------------------------------------------------------------------
  trackStream = (id: string, profile: StreamProfile) => this.get<TrackStream>(`/v1/tracks/${enc(id)}/stream`, { profile });
  videoStream = (id: string) => this.get<VideoStream>(`/v1/videos/${enc(id)}/stream`);
  sendPlaybackEvents = (events: PlaybackEvent[], keepalive = false) => this.request<void>('POST', '/v1/me/playback/events', { body: { events }, keepalive });
  saveTrackProgress = (id: string, positionMs: number, keepalive = false) =>
    this.request<void>('PUT', `/v1/me/progress/tracks/${enc(id)}`, { body: { positionMs: Math.round(positionMs) }, keepalive });
  saveVideoProgress = (id: string, positionMs: number, durationMs: number) =>
    this.request<void>('PUT', `/v1/me/progress/videos/${enc(id)}`, {
      body: { positionMs: Math.round(positionMs), durationMs: Math.round(durationMs), updatedAt: new Date().toISOString() },
    });
  recentlyPlayed = (limit = 30) => this.get<Page<Track>>('/v1/me/recently-played', { limit });
  history = (limit = 50, offset = 0) => this.get<Page<HistoryEntry>>('/v1/me/history', { limit, offset });
  clearHistory = () => this.request<void>('DELETE', '/v1/me/history');
  playbackState = () => this.get<{ state: unknown; version: number; deviceId?: string | null }>('/v1/me/playback-state');
  putPlaybackState = (state: unknown, baseVersion: number, deviceId: string) =>
    this.request<{ version: number }>('PUT', '/v1/me/playback-state', { body: { state, baseVersion, deviceId } });
}

const enc = (s: string) => encodeURIComponent(s);

/**
 * The API builds absolute URLs from PUBLIC_BASE_URL. When the web player is served from the same
 * origin as the API (production), rewrite those to same-origin paths so CSP 'self' always matches and
 * dev proxies work. URLs for other hosts are returned untouched.
 */
export function sameOriginUrl(url: string | null | undefined, apiBase = ''): string | undefined {
  if (!url) return undefined;
  if (apiBase) return url;
  try {
    const u = new URL(url, 'http://placeholder.invalid');
    if (u.pathname.startsWith('/v1/')) return u.pathname + u.search + u.hash;
  } catch {
    /* fall through */
  }
  return url;
}

export const API_BASE = ((import.meta.env?.VITE_API_BASE as string | undefined) ?? '').replace(/\/$/, '');
export const api = new ApiClient({ baseUrl: API_BASE });
export const media = (u: string | null | undefined) => sameOriginUrl(u, API_BASE);
