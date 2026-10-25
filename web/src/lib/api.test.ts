import { describe, expect, it, vi } from 'vitest';
import { ApiClient, ApiError, sameOriginUrl, type TokenStorage } from './api';

function memStorage(initial: string | null = null): TokenStorage & { value: string | null } {
  const s = {
    value: initial,
    get: () => s.value,
    set: (v: string | null) => {
      s.value = v;
    },
  };
  return s;
}

const json = (status: number, body?: unknown) =>
  new Response(body === undefined ? null : JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

const session = (n: number, expiresIn = 900) => ({ accessToken: `at${n}`, refreshToken: `rt${n}`, expiresIn, tokenType: 'Bearer', user: { id: 'u' } });

type Call = { url: string; method: string; auth?: string; body?: any };

function setup(handler: (c: Call) => Response | Promise<Response>, opts: { storage?: TokenStorage; now?: () => number } = {}) {
  const calls: Call[] = [];
  const fetchFn = vi.fn(async (url: RequestInfo | URL, init?: RequestInit) => {
    const headers = (init?.headers ?? {}) as Record<string, string>;
    const c: Call = { url: String(url), method: init?.method ?? 'GET', auth: headers.authorization, body: init?.body ? JSON.parse(String(init.body)) : undefined };
    calls.push(c);
    return handler(c);
  });
  const storage = opts.storage ?? memStorage();
  const client = new ApiClient({ fetch: fetchFn as unknown as typeof fetch, storage, lock: (_n, fn) => fn(), now: opts.now });
  return { client, calls, storage };
}

describe('ApiClient auth', () => {
  it('stores the refresh token and keeps the access token in memory after login', async () => {
    const { client, storage, calls } = setup((c) => (c.url.endsWith('/v1/auth/login') ? json(200, session(1)) : json(200, { ok: true })));
    await client.login('a@b.c', 'pw');
    expect(storage.get()).toBe('rt1');
    await client.get('/v1/me');
    expect(calls[1].auth).toBe('Bearer at1');
    expect(calls[0].body.deviceName).toBe('STREAMERO Web');
  });

  it('refreshes before a request when the access token is about to expire', async () => {
    let t = 0;
    const { client, calls, storage } = setup(
      (c) => (c.url.endsWith('/v1/auth/refresh') ? json(200, session(2)) : json(200, {})),
      { now: () => t },
    );
    client.setSession(session(1, 60));
    t = 40_000; // 20 s left (< 30 s safety margin)
    await client.get('/v1/home');
    expect(calls.map((c) => c.url)).toEqual(['/v1/auth/refresh', '/v1/home']);
    expect(calls[0].body).toEqual({ refreshToken: 'rt1' });
    expect(calls[1].auth).toBe('Bearer at2');
    expect(storage.get()).toBe('rt2');
  });

  it('retries once after a 401 with a refreshed token', async () => {
    let homeCalls = 0;
    const { client, calls } = setup((c) => {
      if (c.url.endsWith('/v1/auth/refresh')) return json(200, session(2));
      homeCalls++;
      return homeCalls === 1 ? json(401, { error: { code: 'unauthorized', message: 'expired' } }) : json(200, { ok: 1 });
    });
    client.setSession(session(1));
    await expect(client.get('/v1/home')).resolves.toEqual({ ok: 1 });
    expect(calls.map((c) => c.auth ?? 'none')).toEqual(['Bearer at1', 'none', 'Bearer at2']);
  });

  it('shares one refresh between concurrent requests (refresh tokens are single-use)', async () => {
    let refreshes = 0;
    const { client } = setup(async (c) => {
      if (c.url.endsWith('/v1/auth/refresh')) {
        refreshes++;
        await new Promise((r) => setTimeout(r, 5));
        return json(200, session(2));
      }
      return json(200, {});
    }, { storage: memStorage('rt1') });
    await Promise.all([client.get('/v1/a'), client.get('/v1/b'), client.get('/v1/c')]);
    expect(refreshes).toBe(1);
  });

  it('signs out when the refresh token is rejected', async () => {
    const { client, storage } = setup((c) => (c.url.endsWith('/v1/auth/refresh') ? json(401, { error: { code: 'invalid_refresh_token', message: 'no' } }) : json(200, {})), {
      storage: memStorage('rt1'),
    });
    const expired = vi.fn();
    client.onSessionExpired = expired;
    await expect(client.get('/v1/me')).rejects.toMatchObject({ code: 'session_expired' });
    expect(storage.get()).toBeNull();
    expect(expired).toHaveBeenCalledOnce();
  });

  it('uses a token rotated by another tab instead of signing out', async () => {
    const storage = memStorage('rt1');
    const { client } = setup((c) => {
      if (c.url.endsWith('/v1/auth/refresh')) {
        if (c.body.refreshToken === 'rt1') {
          storage.set('rt5'); // another tab rotated rt1 → rt5 while our request was in flight
          return json(401, { error: { code: 'refresh_token_reused', message: 'reused' } });
        }
        return json(200, session(6));
      }
      return json(200, { fine: true });
    }, { storage });
    await expect(client.get('/v1/me')).resolves.toEqual({ fine: true });
    expect(storage.get()).toBe('rt6');
  });

  it('keeps the session on network errors during refresh', async () => {
    const { client, storage } = setup((c) => {
      if (c.url.endsWith('/v1/auth/refresh')) throw new TypeError('Failed to fetch');
      return json(200, {});
    }, { storage: memStorage('rt1') });
    await expect(client.get('/v1/me')).rejects.toMatchObject({ code: 'network', status: 0 });
    expect(storage.get()).toBe('rt1');
  });

  it('parses the error envelope', async () => {
    const { client } = setup(() => json(409, { error: { code: 'version_conflict', message: 'Changed elsewhere', details: { version: 4 } } }));
    client.setSession(session(1));
    const err = (await client.get('/v1/x').catch((e) => e)) as ApiError;
    expect(err).toBeInstanceOf(ApiError);
    expect(err.status).toBe(409);
    expect(err.code).toBe('version_conflict');
    expect(err.details).toEqual({ version: 4 });
  });

  it('logout sends the refresh token and clears storage', async () => {
    const { client, calls, storage } = setup(() => new Response(null, { status: 204 }), { storage: memStorage('rt9') });
    await client.logout();
    expect(calls[0]).toMatchObject({ url: '/v1/auth/logout', body: { refreshToken: 'rt9' } });
    expect(storage.get()).toBeNull();
  });

  it('builds query strings and skips empty values', () => {
    const c = new ApiClient({ baseUrl: 'https://x.test/', storage: memStorage() });
    expect(c.url('/v1/search', { q: 'a b', types: 'tracks,artists', limit: 10, x: undefined, y: '' })).toBe('https://x.test/v1/search?q=a+b&types=tracks%2Cartists&limit=10');
  });
});

describe('sameOriginUrl', () => {
  it('rewrites absolute API URLs to same-origin paths', () => {
    expect(sameOriginUrl('http://localhost:8080/v1/artwork/abc?size=small')).toBe('/v1/artwork/abc?size=small');
    expect(sameOriginUrl('https://app.streamero.net/v1/media/tok/master.m3u8')).toBe('/v1/media/tok/master.m3u8');
  });
  it('keeps other URLs and respects an explicit API base', () => {
    expect(sameOriginUrl('https://i.ytimg.com/vi/x/hq.jpg')).toBe('https://i.ytimg.com/vi/x/hq.jpg');
    expect(sameOriginUrl('https://api.example.com/v1/artwork/a', 'https://api.example.com')).toBe('https://api.example.com/v1/artwork/a');
    expect(sameOriginUrl(null)).toBeUndefined();
  });
});
