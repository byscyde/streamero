import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { MailService } from '../../src/mail/mail.service.js';
import { auth, registerUser, startApp, type TestContext } from '../helpers.js';

let ctx: TestContext;
let mail: MailService;
beforeAll(async () => {
  ctx = await startApp();
  mail = ctx.app.get(MailService);
});
afterAll(() => ctx.close());

const tokenFrom = (text: string) => text.match(/token=([\w-]+)/)![1];

describe('authentication', () => {
  it('registers, rejects duplicates and weak passwords, and never returns the hash', async () => {
    const res = await ctx.http.post('/v1/auth/register').send({ email: 'Ana@Example.test', password: 'pass-word-123', displayName: 'Ana' }).expect(201);
    expect(res.body).toMatchObject({ tokenType: 'Bearer', user: { email: 'Ana@Example.test', role: 'user', emailVerified: false } });
    expect(JSON.stringify(res.body)).not.toContain('argon2');
    await ctx.http.post('/v1/auth/register').send({ email: 'ana@example.test', password: 'pass-word-123', displayName: 'Dup' }).expect(409);
    const weak = await ctx.http.post('/v1/auth/register').send({ email: 'b@example.test', password: 'short', displayName: 'B' }).expect(400);
    expect(weak.body.error.code).toBe('validation_failed');
  });

  it('logs in case-insensitively and rejects wrong passwords with a generic error', async () => {
    await ctx.http.post('/v1/auth/login').send({ email: 'ANA@example.test', password: 'pass-word-123' }).expect(200);
    const bad = await ctx.http.post('/v1/auth/login').send({ email: 'ana@example.test', password: 'wrong-password-1' }).expect(401);
    const unknown = await ctx.http.post('/v1/auth/login').send({ email: 'nobody@example.test', password: 'wrong-password-1' }).expect(401);
    expect(bad.body.error.code).toBe('invalid_credentials');
    expect(unknown.body.error.message).toBe(bad.body.error.message);
  });

  it('verifies email with a single-use token', async () => {
    const msg = mail.outbox.find((m) => m.to === 'Ana@Example.test' && m.subject.includes('Verify'))!;
    const token = tokenFrom(msg.text);
    await ctx.http.post('/v1/auth/verify-email').send({ token }).expect(204);
    await ctx.http.post('/v1/auth/verify-email').send({ token }).expect(400);
    const login = await ctx.http.post('/v1/auth/login').send({ email: 'ana@example.test', password: 'pass-word-123' }).expect(200);
    expect(login.body.user.emailVerified).toBe(true);
  });

  it('rotates refresh tokens and revokes the family on reuse', async () => {
    const u = await registerUser(ctx);
    const r1 = await ctx.http.post('/v1/auth/refresh').send({ refreshToken: u.refreshToken }).expect(200);
    expect(r1.body.refreshToken).not.toBe(u.refreshToken);
    const r2 = await ctx.http.post('/v1/auth/refresh').send({ refreshToken: r1.body.refreshToken }).expect(200);
    // Replaying the first (already rotated) token = theft signal.
    const reuse = await ctx.http.post('/v1/auth/refresh').send({ refreshToken: u.refreshToken }).expect(401);
    expect(reuse.body.error.code).toBe('refresh_token_reused');
    // ...which also kills the newest token of that family.
    await ctx.http.post('/v1/auth/refresh').send({ refreshToken: r2.body.refreshToken }).expect(401);
  });

  it('resets the password and signs out all sessions', async () => {
    const u = await registerUser(ctx);
    await ctx.http.post('/v1/auth/forgot-password').send({ email: u.email }).expect(202);
    await ctx.http.post('/v1/auth/forgot-password').send({ email: 'missing@example.test' }).expect(202);
    const token = tokenFrom(mail.outbox.filter((m) => m.to === u.email && m.subject.includes('Reset')).at(-1)!.text);
    await ctx.http.post('/v1/auth/reset-password').send({ token, password: 'brand-new-pass-9' }).expect(204);
    await ctx.http.post('/v1/auth/refresh').send({ refreshToken: u.refreshToken }).expect(401);
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: 'brand-new-pass-9' }).expect(200);
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: u.password }).expect(401);
  });

  it('requires valid tokens and blocks disabled accounts immediately', async () => {
    await ctx.http.get('/v1/me').expect(401);
    const bad = await ctx.http.get('/v1/me').set(auth('not-a-jwt')).expect(401);
    expect(bad.body.error.code).toBe('invalid_token');
    const u = await registerUser(ctx);
    await ctx.http.get('/v1/me').set(auth(u.token)).expect(200);
    await ctx.db.query('UPDATE users SET disabled_at = now() WHERE id = $1', [u.id]);
    await ctx.http.get('/v1/me').set(auth(u.token)).expect(401);
    const login = await ctx.http.post('/v1/auth/login').send({ email: u.email, password: u.password }).expect(403);
    expect(login.body.error.code).toBe('account_disabled');
  });

  it('reports Sign in with Apple as not configured when no client ids are set', async () => {
    const res = await ctx.http.post('/v1/auth/apple').send({ identityToken: 'x'.repeat(40) }).expect(501);
    expect(res.body.error.code).toBe('apple_not_configured');
  });
});

describe('authorization', () => {
  it('enforces roles server-side for the admin API', async () => {
    const user = await registerUser(ctx);
    const editor = await registerUser(ctx, 'editor');
    const admin = await registerUser(ctx, 'admin');
    await ctx.http.get('/v1/admin/overview').set(auth(user.token)).expect(403);
    await ctx.http.get('/v1/admin/overview').set(auth(editor.token)).expect(200);
    await ctx.http.get('/v1/admin/users').set(auth(editor.token)).expect(403);
    await ctx.http.get('/v1/admin/users').set(auth(admin.token)).expect(200);
    // Role comes from the database, so a promotion/demotion takes effect without a new token.
    await ctx.db.query(`UPDATE users SET role = 'user' WHERE id = $1`, [editor.id]);
    await ctx.http.get('/v1/admin/overview').set(auth(editor.token)).expect(403);
  });

  it('protects the last administrator', async () => {
    await ctx.db.query(`UPDATE users SET role = 'user' WHERE role = 'admin'`);
    const admin = await registerUser(ctx, 'admin');
    const res = await ctx.http.patch(`/v1/admin/users/${admin.id}`).set(auth(admin.token)).send({ role: 'user' }).expect(409);
    expect(res.body.error.code).toBe('last_admin');
  });

  it('exports and deletes the account', async () => {
    const u = await registerUser(ctx);
    const exp = await ctx.http.get('/v1/me/export').set(auth(u.token)).expect(200);
    expect(exp.body.profile.email).toBe(u.email);
    expect(JSON.stringify(exp.body)).not.toMatch(/password_hash|argon2/);
    await ctx.http.delete('/v1/me').set(auth(u.token)).send({ password: 'nope-nope-1' }).expect(401);
    await ctx.http.delete('/v1/me').set(auth(u.token)).send({ password: u.password }).expect(204);
    await ctx.http.get('/v1/me').set(auth(u.token)).expect(401);
  });

  it('syncs preferences with optimistic concurrency', async () => {
    const u = await registerUser(ctx);
    const a = await ctx.http.put('/v1/me/preferences').set(auth(u.token)).send({ preferences: { quality: 'high' }, baseVersion: 0 }).expect(200);
    expect(a.body.version).toBe(1);
    const stale = await ctx.http.put('/v1/me/preferences').set(auth(u.token)).send({ preferences: { quality: 'data_saver' }, baseVersion: 0 }).expect(409);
    expect(stale.body.error.details.preferences.quality).toBe('high');
  });

  it('returns structured errors for malformed ids', async () => {
    const u = await registerUser(ctx);
    const res = await ctx.http.get('/v1/tracks/not-a-uuid').set(auth(u.token)).expect(400);
    expect(res.body.error.code).toBe('invalid_identifier');
    expect(res.body.requestId).toBeTruthy();
  });
});
