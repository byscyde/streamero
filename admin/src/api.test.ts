import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, formatBytes, formatDuration, login, request } from './api';

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
