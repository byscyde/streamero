import { describe, expect, it } from 'vitest';
import {
  base64url, beginGoogleSignIn, buildGoogleAuthUrl, createPendingAuth, GOOGLE_PENDING_KEY, GOOGLE_PENDING_TTL_MS, googleRedirectUri,
  googleWebClientId, parseCallbackHash, randomToken, safeReturnPath, takePending, validateCallback, type KeyValueStorage,
} from './googleAuth';
import { DEFAULT_CONFIG, mergeConfig } from './appearance';

function memStorage(): KeyValueStorage & { data: Map<string, string> } {
  const data = new Map<string, string>();
  return { data, getItem: (k) => data.get(k) ?? null, setItem: (k, v) => void data.set(k, v), removeItem: (k) => void data.delete(k) };
}

let counter = 0;
const fakeFill = (b: Uint8Array<ArrayBuffer>) => {
  for (let i = 0; i < b.length; i++) b[i] = (counter + i) & 255;
  counter += 7;
  return b;
};

describe('googleAuth tokens', () => {
  it('encodes base64url without padding or unsafe characters', () => {
    expect(base64url(new Uint8Array([251, 255, 191]))).toBe('-_-_');
    expect(base64url(new Uint8Array([1]))).toBe('AQ');
  });

  it('generates distinct 43-character random tokens with crypto.getRandomValues', () => {
    const a = randomToken();
    const b = randomToken();
    expect(a).toMatch(/^[A-Za-z0-9_-]{43}$/);
    expect(a).not.toBe(b);
  });
});

describe('safeReturnPath', () => {
  it('only keeps same-origin paths', () => {
    expect(safeReturnPath('/album/1?x=2')).toBe('/album/1?x=2');
    expect(safeReturnPath(null)).toBe('/');
    expect(safeReturnPath('https://evil.example/')).toBe('/');
    expect(safeReturnPath('//evil.example/')).toBe('/');
    expect(safeReturnPath('/\\evil.example')).toBe('/');
    expect(safeReturnPath('javascript:alert(1)')).toBe('/');
    expect(safeReturnPath('/auth/google')).toBe('/');
  });
});

describe('buildGoogleAuthUrl', () => {
  it('builds an OIDC implicit-flow request', () => {
    const u = new URL(buildGoogleAuthUrl({ clientId: 'cid.apps.googleusercontent.com', redirectUri: googleRedirectUri('https://app.streamero.net'), state: 'S', nonce: 'N' }));
    expect(u.origin + u.pathname).toBe('https://accounts.google.com/o/oauth2/v2/auth');
    expect(Object.fromEntries(u.searchParams)).toEqual({
      client_id: 'cid.apps.googleusercontent.com',
      redirect_uri: 'https://app.streamero.net/auth/google',
      response_type: 'id_token',
      scope: 'openid email profile',
      nonce: 'N',
      state: 'S',
      prompt: 'select_account',
    });
  });

  it('begins sign-in by storing state/nonce with a 10-minute expiry and redirecting', () => {
    const storage = memStorage();
    let assigned = '';
    beginGoogleSignIn({ clientId: 'cid', origin: 'https://app.streamero.net', returnTo: '/library', storage, assign: (u) => (assigned = u), now: 1000, fill: fakeFill });
    const stored = JSON.parse(storage.data.get(GOOGLE_PENDING_KEY)!);
    expect(stored.returnTo).toBe('/library');
    expect(stored.expiresAt).toBe(1000 + GOOGLE_PENDING_TTL_MS);
    expect(GOOGLE_PENDING_TTL_MS).toBe(600_000);
    const u = new URL(assigned);
    expect(u.searchParams.get('state')).toBe(stored.state);
    expect(u.searchParams.get('nonce')).toBe(stored.nonce);
    expect(stored.state).not.toBe(stored.nonce);
  });
});

describe('callback handling', () => {
  it('parses tokens and errors from the fragment', () => {
    expect(parseCallbackHash('#state=abc&id_token=x.y.z&authuser=0&prompt=consent')).toEqual({ kind: 'token', idToken: 'x.y.z', state: 'abc' });
    expect(parseCallbackHash('#error=access_denied&state=abc')).toEqual({ kind: 'error', error: 'access_denied', description: null, state: 'abc' });
    expect(parseCallbackHash('')).toEqual({ kind: 'empty' });
    expect(parseCallbackHash('#foo=bar')).toEqual({ kind: 'empty' });
  });

  const pending = createPendingAuth('/settings', 0, fakeFill);

  it('accepts a matching, unexpired state and returns the stored nonce', () => {
    const r = validateCallback({ kind: 'token', idToken: 't', state: pending.state }, pending, 1000);
    expect(r).toEqual({ ok: true, idToken: 't', nonce: pending.nonce, returnTo: '/settings' });
  });

  it('rejects a wrong or missing state, missing pending data and expiry', () => {
    expect(validateCallback({ kind: 'token', idToken: 't', state: 'other' }, pending, 1000)).toMatchObject({ ok: false, reason: 'invalid_state' });
    expect(validateCallback({ kind: 'token', idToken: 't', state: null }, pending, 1000)).toMatchObject({ ok: false, reason: 'invalid_state' });
    expect(validateCallback({ kind: 'token', idToken: 't', state: pending.state }, null, 1000)).toMatchObject({ ok: false, reason: 'invalid_state', returnTo: '/' });
    expect(validateCallback({ kind: 'token', idToken: 't', state: pending.state }, pending, pending.expiresAt + 1)).toMatchObject({ ok: false, reason: 'expired' });
    expect(validateCallback({ kind: 'empty' }, pending, 1000)).toMatchObject({ ok: false, reason: 'missing' });
  });

  it('distinguishes a cancelled consent from other provider errors', () => {
    expect(validateCallback({ kind: 'error', error: 'access_denied', description: null, state: pending.state }, pending, 1)).toMatchObject({ ok: false, reason: 'cancelled' });
    expect(validateCallback({ kind: 'error', error: 'invalid_request', description: 'bad', state: pending.state }, pending, 1)).toMatchObject({ ok: false, reason: 'provider_error', detail: 'invalid_request' });
  });

  it('reads the pending request once and ignores malformed entries', () => {
    const s = memStorage();
    s.setItem(GOOGLE_PENDING_KEY, JSON.stringify({ ...pending, returnTo: '//evil' }));
    expect(takePending(s)).toEqual({ ...pending, returnTo: '/' });
    expect(takePending(s)).toBeNull();
    s.setItem(GOOGLE_PENDING_KEY, '{nope');
    expect(takePending(s)).toBeNull();
    s.setItem(GOOGLE_PENDING_KEY, JSON.stringify({ state: 'a' }));
    expect(takePending(s)).toBeNull();
  });
});

describe('Google button visibility', () => {
  it('needs both the feature flag and a web client id from the server', () => {
    expect(googleWebClientId(DEFAULT_CONFIG)).toBeNull();
    const on = mergeConfig({ auth: { googleWebClientId: 'web-cid', googleIosClientId: 'ios-cid' } });
    expect(on.auth).toEqual({ googleWebClientId: 'web-cid', googleIosClientId: 'ios-cid' });
    expect(googleWebClientId(on)).toBe('web-cid');
    expect(googleWebClientId(mergeConfig({ auth: { googleWebClientId: 'web-cid' }, features: { googleSignIn: false } }))).toBeNull();
    expect(mergeConfig({ auth: { googleWebClientId: 42 } }).auth.googleWebClientId).toBeNull();
    expect(mergeConfig({ features: { appleSignIn: true } }).features).not.toHaveProperty('appleSignIn');
  });
});
