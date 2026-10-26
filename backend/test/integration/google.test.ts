import { exportJWK, generateKeyPair, SignJWT } from 'jose';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';
import { auth, registerUser, startApp, type TestContext } from '../helpers.js';

// Google's signing keys are replaced by a local key pair: jose fetches the JWKS with global fetch.
const CLIENT_ID = 'test-web.apps.googleusercontent.com';
let ctx: TestContext;
let privateKey: CryptoKey;
const realFetch = globalThis.fetch;

beforeAll(async () => {
  const pair = await generateKeyPair('RS256');
  privateKey = pair.privateKey;
  const jwk = { ...(await exportJWK(pair.publicKey)), kid: 'test-key', alg: 'RS256', use: 'sig' };
  vi.spyOn(globalThis, 'fetch').mockImplementation(async (input, init) => {
    const url = typeof input === 'string' ? input : input instanceof URL ? input.href : input.url;
    if (url === 'https://www.googleapis.com/oauth2/v3/certs') {
      return new Response(JSON.stringify({ keys: [jwk] }), { headers: { 'content-type': 'application/json' } });
    }
    return realFetch(input, init);
  });
  ctx = await startApp();
});
afterAll(async () => {
  vi.restoreAllMocks();
  await ctx.close();
});

function idToken(claims: Record<string, unknown>, opts: { aud?: string; iss?: string; key?: CryptoKey } = {}) {
  return new SignJWT({ email_verified: true, ...claims })
    .setProtectedHeader({ alg: 'RS256', kid: 'test-key' })
    .setIssuer(opts.iss ?? 'https://accounts.google.com')
    .setAudience(opts.aud ?? CLIENT_ID)
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(opts.key ?? privateKey);
}

describe('Google sign-in', () => {
  it('creates an account on first sign-in and returns the same account afterwards', async () => {
    const token = await idToken({ sub: 'g-1', email: 'Mila@Gmail.test', name: 'Mila', nonce: 'n-1' });
    const first = await ctx.http.post('/v1/auth/google').send({ idToken: token, nonce: 'n-1' }).expect(200);
    expect(first.body).toMatchObject({ tokenType: 'Bearer', user: { email: 'mila@gmail.test', displayName: 'Mila', emailVerified: true } });
    const me = await ctx.http.get('/v1/me').set(auth(first.body.accessToken)).expect(200);
    expect(me.body).toMatchObject({ googleLinked: true, hasPassword: false });

    const again = await ctx.http.post('/v1/auth/google').send({ idToken: await idToken({ sub: 'g-1', email: 'mila@gmail.test' }) }).expect(200);
    expect(again.body.user.id).toBe(first.body.user.id);
  });

  it('links to an existing email account with the same address', async () => {
    const u = await registerUser(ctx);
    const res = await ctx.http.post('/v1/auth/google').send({ idToken: await idToken({ sub: 'g-2', email: u.email.toUpperCase() }) }).expect(200);
    expect(res.body.user.id).toBe(u.id);
    // The password still works after linking.
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: u.password }).expect(200);
  });

  it('rejects tokens for another client, from another issuer, with a wrong nonce, unverified email or forged signature', async () => {
    const other = await generateKeyPair('RS256');
    const cases = [
      await idToken({ sub: 'g-3', email: 'x@gmail.test' }, { aud: 'someone-else.apps.googleusercontent.com' }),
      await idToken({ sub: 'g-3', email: 'x@gmail.test' }, { iss: 'https://evil.example' }),
      await idToken({ sub: 'g-3', email: 'x@gmail.test', email_verified: false }),
      await idToken({ sub: 'g-3', email: 'x@gmail.test' }, { key: other.privateKey }),
    ];
    for (const token of cases) {
      const res = await ctx.http.post('/v1/auth/google').send({ idToken: token }).expect(401);
      expect(res.body.error.code).toBe('invalid_google_token');
    }
    const nonce = await idToken({ sub: 'g-3', email: 'x@gmail.test', nonce: 'expected' });
    await ctx.http.post('/v1/auth/google').send({ idToken: nonce, nonce: 'different' }).expect(401);
  });

  it('blocks disabled accounts and exposes the client ids in the public app config', async () => {
    const res = await ctx.http.post('/v1/auth/google').send({ idToken: await idToken({ sub: 'g-4', email: 'off@gmail.test' }) }).expect(200);
    await ctx.db.query('UPDATE users SET disabled_at = now() WHERE id = $1', [res.body.user.id]);
    const blocked = await ctx.http.post('/v1/auth/google').send({ idToken: await idToken({ sub: 'g-4', email: 'off@gmail.test' }) }).expect(403);
    expect(blocked.body.error.code).toBe('account_disabled');

    const config = await ctx.http.get('/v1/app/config').expect(200);
    expect(config.body.auth).toEqual({ googleIosClientId: null, googleWebClientId: CLIENT_ID });
    expect(config.body.features.googleSignIn).toBe(true);
    expect(config.body.features).not.toHaveProperty('appleSignIn');
    await ctx.http.post('/v1/auth/apple').send({ identityToken: 'x'.repeat(40) }).expect(404);
  });
});
