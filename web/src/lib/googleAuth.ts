/**
 * "Continue with Google" for the web player: OpenID Connect implicit flow (response_type=id_token) via a
 * full-page redirect, so no third-party script is loaded and the CSP keeps `script-src 'self'`.
 *
 * 1. `beginGoogleSignIn` creates a random `state` (CSRF) and `nonce` (replay protection), keeps them in
 *    sessionStorage for 10 minutes together with the path to return to, and redirects to Google.
 * 2. Google redirects back to `/auth/google#id_token=…&state=…` (or `#error=…`).
 * 3. `parseCallbackHash` + `validateCallback` check the state and expiry; the page then posts the ID token
 *    and nonce to `POST /v1/auth/google`, which verifies the token signature, audience and nonce.
 *
 * Everything here is pure (storage, randomness and clock are injected) so it is unit-tested.
 */

export const GOOGLE_AUTH_ENDPOINT = 'https://accounts.google.com/o/oauth2/v2/auth';
export const GOOGLE_CALLBACK_PATH = '/auth/google';
export const GOOGLE_PENDING_KEY = 'streamero.web.google';
export const GOOGLE_PENDING_TTL_MS = 10 * 60 * 1000;

export interface PendingGoogleAuth {
  state: string;
  nonce: string;
  returnTo: string;
  expiresAt: number;
}

export type RandomFill = (bytes: Uint8Array<ArrayBuffer>) => Uint8Array<ArrayBuffer>;

const defaultFill: RandomFill = (b) => crypto.getRandomValues(b);

export function base64url(bytes: Uint8Array): string {
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/** Cryptographically random, URL-safe token (32 bytes → 43 chars). */
export function randomToken(bytes = 32, fill: RandomFill = defaultFill): string {
  return base64url(fill(new Uint8Array(bytes)));
}

/** Only same-origin absolute paths are allowed as return targets (no `//host`, no scheme, not the callback itself). */
export function safeReturnPath(p: string | null | undefined): string {
  if (!p || typeof p !== 'string') return '/';
  if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return '/';
  if (/[\u0000-\u001f]/.test(p)) return '/';
  if (p === GOOGLE_CALLBACK_PATH || p.startsWith(`${GOOGLE_CALLBACK_PATH}?`) || p.startsWith(`${GOOGLE_CALLBACK_PATH}#`)) return '/';
  return p;
}

export function createPendingAuth(returnTo: string | null | undefined, now: number, fill: RandomFill = defaultFill): PendingGoogleAuth {
  return { state: randomToken(32, fill), nonce: randomToken(32, fill), returnTo: safeReturnPath(returnTo), expiresAt: now + GOOGLE_PENDING_TTL_MS };
}

export function buildGoogleAuthUrl(o: { clientId: string; redirectUri: string; state: string; nonce: string }): string {
  const p = new URLSearchParams({
    client_id: o.clientId,
    redirect_uri: o.redirectUri,
    response_type: 'id_token',
    scope: 'openid email profile',
    nonce: o.nonce,
    state: o.state,
    prompt: 'select_account',
  });
  return `${GOOGLE_AUTH_ENDPOINT}?${p.toString()}`;
}

export const googleRedirectUri = (origin: string) => `${origin.replace(/\/$/, '')}${GOOGLE_CALLBACK_PATH}`;

export interface KeyValueStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

export function savePending(storage: KeyValueStorage, p: PendingGoogleAuth) {
  storage.setItem(GOOGLE_PENDING_KEY, JSON.stringify(p));
}

/** Reads and removes the pending request (single use). Malformed entries read as null. */
export function takePending(storage: KeyValueStorage): PendingGoogleAuth | null {
  let raw: string | null = null;
  try {
    raw = storage.getItem(GOOGLE_PENDING_KEY);
    storage.removeItem(GOOGLE_PENDING_KEY);
  } catch {
    return null;
  }
  if (!raw) return null;
  try {
    const v = JSON.parse(raw) as Partial<PendingGoogleAuth>;
    if (typeof v.state !== 'string' || typeof v.nonce !== 'string' || typeof v.expiresAt !== 'number' || !v.state || !v.nonce) return null;
    return { state: v.state, nonce: v.nonce, expiresAt: v.expiresAt, returnTo: safeReturnPath(v.returnTo) };
  } catch {
    return null;
  }
}

/**
 * Starts the redirect. Returns the URL it navigated to. Throws when storage is unavailable, because
 * without the stored state the callback could not be verified.
 */
export function beginGoogleSignIn(o: {
  clientId: string;
  origin: string;
  returnTo?: string | null;
  storage: KeyValueStorage;
  assign: (url: string) => void;
  now?: number;
  fill?: RandomFill;
}): string {
  const pending = createPendingAuth(o.returnTo, o.now ?? Date.now(), o.fill ?? defaultFill);
  savePending(o.storage, pending);
  const url = buildGoogleAuthUrl({ clientId: o.clientId, redirectUri: googleRedirectUri(o.origin), state: pending.state, nonce: pending.nonce });
  o.assign(url);
  return url;
}

export type CallbackHash =
  | { kind: 'token'; idToken: string; state: string | null }
  | { kind: 'error'; error: string; description: string | null; state: string | null }
  | { kind: 'empty' };

export function parseCallbackHash(hash: string): CallbackHash {
  const p = new URLSearchParams(hash.replace(/^#/, ''));
  const state = p.get('state');
  const error = p.get('error');
  if (error) return { kind: 'error', error, description: p.get('error_description'), state };
  const idToken = p.get('id_token');
  if (idToken) return { kind: 'token', idToken, state };
  return { kind: 'empty' };
}

export type CallbackFailure = 'cancelled' | 'provider_error' | 'missing' | 'invalid_state' | 'expired';

export type CallbackResult =
  | { ok: true; idToken: string; nonce: string; returnTo: string }
  | { ok: false; reason: CallbackFailure; returnTo: string; detail?: string };

const CANCEL_ERRORS = new Set(['access_denied', 'user_cancelled', 'interaction_required', 'login_required', 'consent_required', 'account_selection_required']);

export function validateCallback(parsed: CallbackHash, pending: PendingGoogleAuth | null, now: number): CallbackResult {
  const returnTo = pending?.returnTo ?? '/';
  if (parsed.kind === 'empty') return { ok: false, reason: 'missing', returnTo };
  if (!pending || !parsed.state || parsed.state !== pending.state) return { ok: false, reason: 'invalid_state', returnTo };
  if (now > pending.expiresAt) return { ok: false, reason: 'expired', returnTo };
  if (parsed.kind === 'error')
    return { ok: false, reason: CANCEL_ERRORS.has(parsed.error) ? 'cancelled' : 'provider_error', returnTo, detail: parsed.error };
  return { ok: true, idToken: parsed.idToken, nonce: pending.nonce, returnTo };
}

/** Shown when `features.googleSignIn` is on and the server has a web client id. */
export function googleWebClientId(c: { features: { googleSignIn: boolean }; auth: { googleWebClientId: string | null } }): string | null {
  return c.features.googleSignIn && c.auth.googleWebClientId ? c.auth.googleWebClientId : null;
}
