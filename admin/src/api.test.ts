import { afterEach, describe, expect, it, vi } from 'vitest';
import { adminApi, ApiError, formatBytes, formatDuration, isDisplayableImage, login, passwordProblem, request, unwrapList, userPatch, type AdminUser } from './api';

afterEach(() => {
  vi.restoreAllMocks();
  sessionStorage.clear();
});

const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

describe('admin api client', () => {
  it('rejects non-staff accounts at sign in', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(json(200, { accessToken: 'a', refreshToken: 'r', user: { role: 'user' } }));
    await expect(login('u@x', 'p')).rejects.toMatchObject({ code: 'forbidden' });
    expect(sessionStorage.getItem('streamero.admin.refresh')).toBeNull();
  });

  it('refreshes once on 401 and retries', async () => {
    const fetch = vi.spyOn(globalThis, 'fetch');
    fetch.mockResolvedValueOnce(json(200, { accessToken: 'a1', refreshToken: 'r1', user: { role: 'admin' } }));
    await login('a@x', 'p');
    fetch.mockResolvedValueOnce(json(401, { error: { code: 'invalid_token', message: 'x' } }));
    fetch.mockResolvedValueOnce(json(200, { accessToken: 'a2', refreshToken: 'r2' }));
    fetch.mockResolvedValueOnce(json(200, { ok: true }));
    await expect(request('GET', '/v1/admin/overview')).resolves.toEqual({ ok: true });
    expect(sessionStorage.getItem('streamero.admin.refresh')).toBe('r2');
    const last = fetch.mock.calls.at(-1)!;
    expect((last[1] as RequestInit).headers).toMatchObject({ authorization: 'Bearer a2' });
  });

  it('surfaces structured API errors', async () => {
    vi.spyOn(globalThis, 'fetch').mockResolvedValue(json(409, { error: { code: 'album_not_empty', message: 'Album has tracks' } }));
    const err = await request('DELETE', '/v1/x', undefined, false).catch((e) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ status: 409, code: 'album_not_empty' });
  });

  it('formats sizes and durations', () => {
    expect(formatBytes(1_500_000)).toBe('1.5 MB');
    expect(formatDuration(3_723_000)).toBe('1:02:03');
    expect(formatDuration(65_000)).toBe('1:05');
  });
});

describe('typed admin endpoints', () => {
  const signIn = async (fetch: ReturnType<typeof vi.spyOn>) => {
    fetch.mockResolvedValueOnce(json(200, { accessToken: 'tok', refreshToken: 'r', user: { role: 'admin' } }));
    await login('a@x', 'p');
  };
  const call = (fetch: any, i = -1) => {
    const [url, init] = fetch.mock.calls.at(i)!;
    return { url: String(url), method: (init as RequestInit).method, body: (init as RequestInit).body ? JSON.parse(String((init as RequestInit).body)) : undefined, headers: (init as RequestInit).headers };
  };

  it('user management calls the contract paths', async () => {
    const fetch = vi.spyOn(globalThis, 'fetch');
    await signIn(fetch);
    fetch.mockImplementation(async () => json(200, {}));
    await adminApi.users.list({ q: 'ann', role: 'editor', offset: 25, limit: 25 });
    expect(call(fetch).url).toBe('/v1/admin/users?q=ann&role=editor&offset=25&limit=25');
    await adminApi.users.create({ email: 'n@x.io', displayName: 'N', role: 'user', sendInvite: true });
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/users', method: 'POST', body: { email: 'n@x.io', displayName: 'N', role: 'user', sendInvite: true }, headers: { authorization: 'Bearer tok' } });
    await adminApi.users.update('u/1', { emailVerified: true });
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/users/u%2F1', method: 'PATCH', body: { emailVerified: true } });
    await adminApi.users.setPassword('u1', 'abcdefgh12');
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/users/u1/password', method: 'POST', body: { password: 'abcdefgh12' } });
    await adminApi.users.sendReset('u1');
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/users/u1/send-reset', method: 'POST' });
    fetch.mockResolvedValueOnce(new Response(null, { status: 204 }));
    await adminApi.users.remove('u1');
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/users/u1', method: 'DELETE' });
  });

  it('appearance, metadata and self-service auth', async () => {
    const fetch = vi.spyOn(globalThis, 'fetch');
    await signIn(fetch);
    fetch.mockImplementation(async () => json(200, {}));
    await adminApi.appearance.save({ theme: { accent: '#000000' } });
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/appearance', method: 'PUT', body: { theme: { accent: '#000000' } } });
    await adminApi.appearance.reset();
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/appearance/reset', method: 'POST' });
    fetch.mockResolvedValueOnce(json(200, [{ id: 'mb1', title: 'T', artist: 'A' }]));
    await expect(adminApi.metadata.search('a & b')).resolves.toEqual([{ id: 'mb1', title: 'T', artist: 'A' }]);
    expect(call(fetch).url).toBe('/v1/admin/metadata/search?q=a+%26+b');
    await adminApi.metadata.apply({ trackId: 't1', recordingId: 'mb1', releaseId: 'rel', overwrite: true });
    expect(call(fetch)).toMatchObject({ url: '/v1/admin/metadata/apply', method: 'POST', body: { trackId: 't1', recordingId: 'mb1', releaseId: 'rel', overwrite: true } });
    fetch.mockResolvedValueOnce(new Response(null, { status: 204 }));
    await adminApi.auth.changePassword('old', 'newpassword1');
    expect(call(fetch)).toMatchObject({ url: '/v1/auth/change-password', method: 'POST', body: { currentPassword: 'old', newPassword: 'newpassword1' } });
    fetch.mockResolvedValueOnce(json(202, { status: 'sent' }));
    await expect(adminApi.auth.forgotPassword('a@x')).resolves.toEqual({ status: 'sent' });
    const f = call(fetch);
    expect(f).toMatchObject({ url: '/v1/auth/forgot-password', method: 'POST', body: { email: 'a@x' } });
    expect((f.headers as Record<string, string>).authorization).toBeUndefined();
  });

  it('unwraps list responses', () => {
    expect(unwrapList([1])).toEqual([1]);
    expect(unwrapList({ items: [2] })).toEqual([2]);
    expect(unwrapList({ results: [3] })).toEqual([3]);
    expect(unwrapList(null)).toEqual([]);
  });
});

describe('helpers', () => {
  it('checks the password policy', () => {
    expect(passwordProblem('short1')).toMatch(/10/);
    expect(passwordProblem('onlyletterslong')).toMatch(/digits/);
    expect(passwordProblem('1234567890')).toMatch(/letters/);
    expect(passwordProblem('goodpassword1')).toBeNull();
  });
  it('only shows images allowed by the CSP', () => {
    const o = 'https://admin.example';
    expect(isDisplayableImage('/v1/artwork/1', o)).toBe(true);
    expect(isDisplayableImage('https://admin.example/a.jpg', o)).toBe(true);
    expect(isDisplayableImage('https://coverartarchive.org/release/x/front', o)).toBe(false);
    expect(isDisplayableImage('//evil.example/a.png', o)).toBe(false);
    expect(isDisplayableImage('data:image/png;base64,AA', o)).toBe(true);
    expect(isDisplayableImage(null, o)).toBe(false);
  });
  it('builds minimal user patches', () => {
    const u: AdminUser = { id: '1', email: 'a@x.io', displayName: 'A', role: 'user', disabled: false, emailVerified: false, createdAt: '' };
    expect(userPatch(u, { email: ' a@x.io ', displayName: 'A', role: 'user', disabled: false, emailVerified: false })).toEqual({});
    expect(userPatch(u, { email: 'b@x.io', displayName: ' B ', role: 'editor', disabled: true, emailVerified: true })).toEqual({ email: 'b@x.io', displayName: 'B', role: 'editor', disabled: true, emailVerified: true });
  });
});
