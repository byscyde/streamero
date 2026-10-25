/** Thin API client for the dashboard. Uses the same endpoints and auth rules as the apps. */
const BASE = (import.meta.env.VITE_API_BASE as string | undefined)?.replace(/\/$/, '') ?? '';

export interface ApiErrorBody {
  code: string;
  message: string;
  details?: unknown;
}

export class ApiError extends Error {
  constructor(
    readonly status: number,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
  }
}

export interface Page<T> {
  items: T[];
  limit: number;
  offset: number;
  total?: number;
  nextOffset: number | null;
}

// Access token in memory only; the refresh token in sessionStorage so a reload keeps the session
// but closing the tab ends it. The admin never stores tokens in localStorage.
let accessToken: string | null = null;
let refreshing: Promise<boolean> | null = null;
const REFRESH_KEY = 'streamero.admin.refresh';
let onLogout: () => void = () => {};

export function setLogoutHandler(fn: () => void) {
  onLogout = fn;
}

export function hasSession() {
  return !!sessionStorage.getItem(REFRESH_KEY);
}

export async function login(email: string, password: string) {
  const s = await request<any>('POST', '/v1/auth/login', { email, password, deviceName: 'STREAMERO Admin' }, false);
  if (!['admin', 'editor'].includes(s.user.role)) throw new ApiError(403, 'forbidden', 'This account does not have dashboard access');
  accessToken = s.accessToken;
  sessionStorage.setItem(REFRESH_KEY, s.refreshToken);
  return s.user;
}

export async function logout() {
  const rt = sessionStorage.getItem(REFRESH_KEY);
  sessionStorage.removeItem(REFRESH_KEY);
  accessToken = null;
  if (rt) await fetch(`${BASE}/v1/auth/logout`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ refreshToken: rt }) }).catch(() => {});
}

async function refresh(): Promise<boolean> {
  const rt = sessionStorage.getItem(REFRESH_KEY);
  if (!rt) return false;
  refreshing ??= (async () => {
    try {
      const res = await fetch(`${BASE}/v1/auth/refresh`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ refreshToken: rt }) });
      if (!res.ok) {
        sessionStorage.removeItem(REFRESH_KEY);
        return false;
      }
      const s = await res.json();
      accessToken = s.accessToken;
      sessionStorage.setItem(REFRESH_KEY, s.refreshToken);
      return true;
    } finally {
      setTimeout(() => (refreshing = null), 0);
    }
  })();
  return refreshing;
}

export async function request<T>(method: string, path: string, body?: unknown, auth = true, raw?: { data: BodyInit; type: string }): Promise<T> {
  if (auth && !accessToken && !(await refresh())) {
    onLogout();
    throw new ApiError(401, 'unauthorized', 'Please sign in');
  }
  const send = () =>
    fetch(`${BASE}${path}`, {
      method,
      headers: {
        ...(raw ? { 'content-type': raw.type } : body !== undefined ? { 'content-type': 'application/json' } : {}),
        ...(auth && accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
      },
      body: raw ? raw.data : body !== undefined ? JSON.stringify(body) : undefined,
    });
  let res = await send();
  if (res.status === 401 && auth) {
    if (await refresh()) res = await send();
    else {
      onLogout();
      throw new ApiError(401, 'unauthorized', 'Session expired');
    }
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  const json = text ? JSON.parse(text) : undefined;
  if (!res.ok) {
    const e: ApiErrorBody = json?.error ?? { code: `http_${res.status}`, message: res.statusText };
    throw new ApiError(res.status, e.code, e.message, e.details);
  }
  return json as T;
}

export const api = {
  get: <T>(path: string, query?: Record<string, string | number | undefined | null>) => {
    const qs = query ? new URLSearchParams(Object.entries(query).filter(([, v]) => v !== undefined && v !== null && v !== '').map(([k, v]) => [k, String(v)])).toString() : '';
    return request<T>('GET', qs ? `${path}?${qs}` : path);
  },
  post: <T>(path: string, body?: unknown) => request<T>('POST', path, body ?? {}),
  put: <T>(path: string, body?: unknown) => request<T>('PUT', path, body ?? {}),
  patch: <T>(path: string, body: unknown) => request<T>('PATCH', path, body),
  del: <T>(path: string) => request<T>('DELETE', path),
};

export interface UploadProgress {
  sent: number;
  total: number;
}

/**
 * Resumable chunked upload: creates a session, sends chunks with limited parallelism and per-chunk
 * retries, and can resume an interrupted session by asking the server which chunks are missing.
 */
export async function uploadFile(
  file: File,
  purpose: 'media' | 'subtitle' | 'artwork',
  options: Record<string, unknown>,
  onProgress: (p: UploadProgress) => void,
  signal?: AbortSignal,
  resumeId?: string,
) {
  const session = resumeId
    ? await api.get<any>(`/v1/admin/uploads/${resumeId}`)
    : await api.post<any>('/v1/admin/uploads', { filename: file.name, totalBytes: file.size, purpose, options });
  const missing: number[] = [...session.missingChunks];
  let sent = (session.totalChunks - missing.length) * session.chunkBytes;
  onProgress({ sent: Math.min(sent, file.size), total: file.size });
  const worker = async () => {
    while (missing.length) {
      if (signal?.aborted) throw new DOMException('Upload cancelled', 'AbortError');
      const index = missing.shift()!;
      const blob = file.slice(index * session.chunkBytes, Math.min(file.size, (index + 1) * session.chunkBytes));
      for (let attempt = 1; ; attempt++) {
        try {
          await request('PUT', `/v1/admin/uploads/${session.id}/chunks/${index}`, undefined, true, { data: blob, type: 'application/octet-stream' });
          break;
        } catch (err) {
          if (attempt >= 4 || (err instanceof ApiError && err.status < 500 && err.status !== 429)) throw err;
          await new Promise((r) => setTimeout(r, 1000 * 2 ** attempt));
        }
      }
      sent += blob.size;
      onProgress({ sent: Math.min(sent, file.size), total: file.size });
    }
  };
  await Promise.all([worker(), worker(), worker()]);
  return api.post<any>(`/v1/admin/uploads/${session.id}/complete`);
}

export function formatBytes(n: number) {
  if (!n) return '0 B';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.min(u.length - 1, Math.floor(Math.log10(n) / 3));
  return `${(n / 1000 ** i).toFixed(i ? 1 : 0)} ${u[i]}`;
}

export function formatDuration(ms: number) {
  const s = Math.round(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${sec}` : `${m}:${sec}`;
}

// ---------------------------------------------------------------------------------------------------------------
// Typed endpoints (see docs/APP_CONFIG.md). Kept as thin wrappers so pages and tests share one definition.

export type Role = 'user' | 'editor' | 'admin';

export interface AdminUser {
  id: string;
  email: string;
  displayName: string;
  role: Role;
  disabled: boolean;
  emailVerified: boolean;
  createdAt: string;
  lastActiveAt?: string | null;
  lastPlayedAt?: string | null;
}

export interface CreateUserBody {
  email: string;
  displayName: string;
  role: Role;
  password?: string;
  sendInvite?: boolean;
}

export interface UpdateUserBody {
  email?: string;
  displayName?: string;
  role?: Role;
  disabled?: boolean;
  emailVerified?: boolean;
}

export interface MetadataResult {
  id: string;
  title: string;
  artist: string;
  album?: string | null;
  albumId?: string | null;
  year?: number | string | null;
  durationMs?: number | null;
  genres?: string[];
  coverUrl?: string | null;
}

const enc = encodeURIComponent;

/** The search endpoint returns "up to 25 recordings"; accept a bare array or a `{ items | results }` wrapper. */
export function unwrapList<T>(r: unknown): T[] {
  if (Array.isArray(r)) return r as T[];
  const o = r as { items?: T[]; results?: T[] } | null | undefined;
  return o?.items ?? o?.results ?? [];
}

export const adminApi = {
  users: {
    list: (q: { q?: string; role?: string; limit?: number; offset?: number }) => api.get<Page<AdminUser>>('/v1/admin/users', q),
    create: (body: CreateUserBody) => api.post<AdminUser>('/v1/admin/users', body),
    update: (id: string, body: UpdateUserBody) => api.patch<AdminUser>(`/v1/admin/users/${enc(id)}`, body),
    setPassword: (id: string, password: string) => api.post<void>(`/v1/admin/users/${enc(id)}/password`, { password }),
    sendReset: (id: string) => api.post<void>(`/v1/admin/users/${enc(id)}/send-reset`),
    remove: (id: string) => api.del<void>(`/v1/admin/users/${enc(id)}`),
  },
  appearance: {
    get: () => api.get<any>('/v1/admin/appearance'),
    save: (doc: unknown) => api.put<any>('/v1/admin/appearance', doc),
    reset: () => api.post<any>('/v1/admin/appearance/reset'),
  },
  metadata: {
    search: async (q: string) => unwrapList<MetadataResult>(await api.get<unknown>('/v1/admin/metadata/search', { q })),
    apply: (body: { trackId: string; recordingId: string; releaseId?: string; overwrite?: boolean }) => api.post<any>('/v1/admin/metadata/apply', body),
  },
  auth: {
    changePassword: (currentPassword: string, newPassword: string) => api.post<void>('/v1/auth/change-password', { currentPassword, newPassword }),
    forgotPassword: (email: string) => request<{ status?: string } | undefined>('POST', '/v1/auth/forgot-password', { email }, false),
  },
};

/** Server password policy: at least 10 characters with letters and digits. Returns a problem or null. */
export function passwordProblem(pw: string): string | null {
  if (pw.length < 10) return 'Use at least 10 characters.';
  if (!/\p{L}/u.test(pw) || !/\d/.test(pw)) return 'Use both letters and digits.';
  if (pw.length > 256) return 'Password is too long.';
  return null;
}

/** Hosts the dashboard CSP allows images from besides itself (MusicBrainz cover art, see infra/nginx.conf). */
const IMAGE_HOSTS = [/^coverartarchive\.org$/, /^([a-z0-9-]+\.)*archive\.org$/];

/** Returns true only for image URLs the dashboard CSP lets the browser load. */
export function isDisplayableImage(url: string | null | undefined, origin = typeof location !== 'undefined' ? location.origin : ''): boolean {
  if (!url) return false;
  if (url.startsWith('data:image/') || url.startsWith('blob:')) return true;
  if (url.startsWith('//')) return false;
  if (url.startsWith('/')) return true;
  try {
    const u = new URL(url);
    if (u.origin === origin) return true;
    return u.protocol === 'https:' && IMAGE_HOSTS.some((re) => re.test(u.hostname));
  } catch {
    return false;
  }
}

/** Only the fields that changed (strings trimmed), so PATCH requests and audit entries stay minimal. */
export function userPatch(user: AdminUser, form: Required<Pick<UpdateUserBody, 'email' | 'displayName' | 'role' | 'disabled' | 'emailVerified'>>): UpdateUserBody {
  const out: UpdateUserBody = {};
  const email = form.email.trim();
  const displayName = form.displayName.trim();
  if (email !== user.email) out.email = email;
  if (displayName !== user.displayName) out.displayName = displayName;
  if (form.role !== user.role) out.role = form.role;
  if (form.disabled !== user.disabled) out.disabled = form.disabled;
  if (form.emailVerified !== user.emailVerified) out.emailVerified = form.emailVerified;
  return out;
}
