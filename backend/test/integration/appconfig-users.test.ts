import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { DEFAULT_APPEARANCE } from '../../src/appconfig/appconfig.schema.js';
import { MailService } from '../../src/mail/mail.service.js';
import { auth, registerUser, startApp, type TestContext } from '../helpers.js';

let ctx: TestContext;
let mail: MailService;
let admin: Awaited<ReturnType<typeof registerUser>>;
let editor: Awaited<ReturnType<typeof registerUser>>;
let listener: Awaited<ReturnType<typeof registerUser>>;

beforeAll(async () => {
  ctx = await startApp();
  mail = ctx.app.get(MailService);
  admin = await registerUser(ctx, 'admin');
  editor = await registerUser(ctx, 'editor');
  listener = await registerUser(ctx);
});
afterAll(() => ctx.close());

const tokenFrom = (text: string) => text.match(/token=([\w-]+)/)![1];
const lastMailTo = (to: string) => mail.outbox.filter((m) => m.to === to).at(-1)!;

describe('remote app config', () => {
  it('serves the full default document publicly with caching headers and ETag/304', async () => {
    const res = await ctx.http.get('/v1/app/config').expect(200);
    const { version, ...doc } = res.body;
    expect(doc).toEqual(DEFAULT_APPEARANCE);
    expect(version).toMatch(/^[0-9a-f]{16}$/);
    expect(res.headers['cache-control']).toBe('public, max-age=30');
    expect(res.headers.etag).toBe(`"${version}"`);
    await ctx.http.get('/v1/app/config').set('If-None-Match', res.headers.etag).expect(304);
    await ctx.http.get('/v1/app/config').set('If-None-Match', '"something-else"').expect(200);
  });

  it('is admin-only to read with defaults and to change', async () => {
    await ctx.http.get('/v1/admin/appearance').expect(401);
    await ctx.http.get('/v1/admin/appearance').set(auth(editor.token)).expect(403);
    await ctx.http.put('/v1/admin/appearance').set(auth(listener.token)).send({ theme: { accent: '#00FF00' } }).expect(403);
    await ctx.http.post('/v1/admin/appearance/reset').set(auth(editor.token)).expect(403);
    const res = await ctx.http.get('/v1/admin/appearance').set(auth(admin.token)).expect(200);
    expect(res.body.defaults).toEqual(DEFAULT_APPEARANCE);
    expect(res.body.theme.accent).toBe('#E31E2D');
  });

  it('rejects invalid documents with field paths', async () => {
    const bad = async (body: object, path: string) => {
      const res = await ctx.http.put('/v1/admin/appearance').set(auth(admin.token)).send(body).expect(400);
      expect(res.body.error.code).toBe('validation_failed');
      expect(res.body.error.details.map((d: any) => d.path)).toContain(path);
    };
    await bad({ theme: { accent: 'red' } }, 'theme.accent');
    await bad({ theme: { accent: '#12345' } }, 'theme.accent');
    await bad({ theme: { cornerRadius: 29 } }, 'theme.cornerRadius');
    await bad({ theme: { titleFont: 'comic' } }, 'theme.titleFont');
    await bad({ home: { chips: ['All', 'Podcasts'] } }, 'home.chips.1');
    await bad({ home: { chips: ['All', 'All'] } }, 'home.chips');
    await bad({ home: { sectionsOrder: ['genres', 'nope'] } }, 'home.sectionsOrder.1');
    await bad({ brand: { appName: 'x'.repeat(41) } }, 'brand.appName');
    await bad({ announcement: { style: 'danger' } }, 'announcement.style');
    const unknown = await ctx.http.put('/v1/admin/appearance').set(auth(admin.token)).send({ theme: { sparkle: true } }).expect(400);
    expect(unknown.body.error.code).toBe('validation_failed');
    await ctx.http.put('/v1/admin/appearance').set(auth(admin.token)).send({ extra: {} }).expect(400);
  });

  it('applies partial updates over defaults, bumps the version and propagates it to sync state', async () => {
    const before = (await ctx.http.get('/v1/app/config').expect(200)).body.version;
    const sync0 = await ctx.http.get('/v1/sync/state').set(auth(listener.token)).expect(200);
    expect(sync0.body.configVersion).toBe(before);

    const res = await ctx.http
      .put('/v1/admin/appearance')
      .set(auth(admin.token))
      .send({ theme: { accent: '#1DB954', cornerRadius: 20 }, announcement: { enabled: true, text: 'Maintenance tonight', style: 'warning' } })
      .expect(200);
    expect(res.body.theme).toMatchObject({ accent: '#1DB954', cornerRadius: 20, onAccent: '#FFFFFF', titleFont: 'mono' });
    expect(res.body.version).not.toBe(before);

    // A second partial update keeps the earlier change; echoing back version/defaults is tolerated.
    const second = await ctx.http
      .put('/v1/admin/appearance')
      .set(auth(admin.token))
      .send({ version: 'stale', defaults: {}, home: { chips: ['Music', 'All'] }, features: { radio: false } })
      .expect(200);
    expect(second.body.theme.accent).toBe('#1DB954');
    expect(second.body.home).toEqual({ chips: ['Music', 'All'], sectionsOrder: DEFAULT_APPEARANCE.home.sectionsOrder });
    expect(second.body.features).toMatchObject({ radio: false, videos: true });

    const pub = await ctx.http.get('/v1/app/config').expect(200);
    expect(pub.body).toEqual(second.body);
    const sync1 = await ctx.http.get('/v1/sync/state').set(auth(listener.token)).expect(200);
    expect(sync1.body.configVersion).toBe(second.body.version);

    const audit = await ctx.http.get('/v1/admin/audit-logs').query({ action: 'appearance.' }).set(auth(admin.token)).expect(200);
    expect(audit.body.items[0].metadata.fields).toEqual(['home.chips', 'features.radio']);
  });

  it('resets to defaults', async () => {
    const res = await ctx.http.post('/v1/admin/appearance/reset').set(auth(admin.token)).expect(200);
    const { version, ...doc } = res.body;
    expect(doc).toEqual(DEFAULT_APPEARANCE);
    const sync = await ctx.http.get('/v1/sync/state').set(auth(listener.token)).expect(200);
    expect(sync.body.configVersion).toBe(version);
  });
});

describe('admin user management', () => {
  let createdId: string;

  it('creates verified accounts, rejects duplicates and non-admins', async () => {
    const body = { email: 'mira@example.test', displayName: 'Mira', role: 'editor', password: 'mira-password-1' };
    await ctx.http.post('/v1/admin/users').set(auth(editor.token)).send(body).expect(403);
    const res = await ctx.http.post('/v1/admin/users').set(auth(admin.token)).send(body).expect(201);
    expect(res.body).toMatchObject({ email: 'mira@example.test', displayName: 'Mira', role: 'editor', emailVerified: true, disabled: false });
    createdId = res.body.id;
    const dup = await ctx.http.post('/v1/admin/users').set(auth(admin.token)).send({ ...body, email: 'MIRA@example.test' }).expect(409);
    expect(dup.body.error.code).toBe('email_taken');
    await ctx.http.post('/v1/admin/users').set(auth(admin.token)).send({ ...body, email: 'weak@example.test', password: 'short' }).expect(400);
    const login = await ctx.http.post('/v1/auth/login').send({ email: 'mira@example.test', password: 'mira-password-1' }).expect(200);
    expect(login.body.user.role).toBe('editor');
  });

  it('invites a user without a password via a set-password link to the web player', async () => {
    const res = await ctx.http.post('/v1/admin/users').set(auth(admin.token)).send({ email: 'invitee@example.test', displayName: 'Invitee', role: 'user' }).expect(201);
    const msg = lastMailTo('invitee@example.test');
    expect(msg.text).toContain('https://app.streamero.net/reset-password?token=');
    expect(msg.text).toContain('web browser');
    await ctx.http.post('/v1/auth/reset-password').send({ token: tokenFrom(msg.text), password: 'invitee-pass-77' }).expect(204);
    const login = await ctx.http.post('/v1/auth/login').send({ email: 'invitee@example.test', password: 'invitee-pass-77' }).expect(200);
    expect(login.body.user.id).toBe(res.body.id);
  });

  it('updates email, display name and verification; email must stay unique', async () => {
    const res = await ctx.http
      .patch(`/v1/admin/users/${createdId}`)
      .set(auth(admin.token))
      .send({ email: 'mira.new@example.test', displayName: 'Mira N', emailVerified: false })
      .expect(200);
    expect(res.body).toMatchObject({ id: createdId, email: 'mira.new@example.test', displayName: 'Mira N', emailVerified: false, role: 'editor' });
    const taken = await ctx.http.patch(`/v1/admin/users/${createdId}`).set(auth(admin.token)).send({ email: listener.email }).expect(409);
    expect(taken.body.error.code).toBe('email_taken');
    const list = await ctx.http.get('/v1/admin/users').query({ q: 'mira.new' }).set(auth(admin.token)).expect(200);
    expect(list.body.items[0]).toMatchObject({ id: createdId, emailVerified: false });
    expect(list.body.items[0]).toHaveProperty('lastActiveAt');
  });

  it('sets a password, revoking sessions, and the user can log in with it', async () => {
    const u = await registerUser(ctx);
    await ctx.http.post(`/v1/admin/users/${u.id}/password`).set(auth(admin.token)).send({ password: 'short' }).expect(400);
    await ctx.http.post(`/v1/admin/users/${u.id}/password`).set(auth(editor.token)).send({ password: 'admin-set-pass-1' }).expect(403);
    await ctx.http.post(`/v1/admin/users/${u.id}/password`).set(auth(admin.token)).send({ password: 'admin-set-pass-1' }).expect(204);
    await ctx.http.post('/v1/auth/refresh').send({ refreshToken: u.refreshToken }).expect(401);
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: u.password }).expect(401);
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: 'admin-set-pass-1' }).expect(200);
  });

  it('sends a password reset email', async () => {
    const u = await registerUser(ctx);
    await ctx.http.post(`/v1/admin/users/${u.id}/send-reset`).set(auth(admin.token)).expect(202);
    const msg = lastMailTo(u.email);
    expect(msg.subject).toContain('Reset');
    expect(msg.text).toMatch(/^https:\/\/app\.streamero\.net\/reset-password\?token=[\w-]+$/m);
    await ctx.http.post('/v1/auth/reset-password').send({ token: tokenFrom(msg.text), password: 'reset-by-admin-2' }).expect(204);
    await ctx.http.post('/v1/auth/login').send({ email: u.email, password: 'reset-by-admin-2' }).expect(200);
    await ctx.http.post(`/v1/admin/users/00000000-0000-4000-8000-000000000000/send-reset`).set(auth(admin.token)).expect(404);
  });

  it('deletes accounts with their personal data and audits every action', async () => {
    const u = await registerUser(ctx);
    const pl = await ctx.http.post('/v1/playlists').set(auth(u.token)).send({ title: 'Mine' });
    expect([200, 201]).toContain(pl.status);
    await ctx.http.delete(`/v1/admin/users/${u.id}`).set(auth(editor.token)).expect(403);
    await ctx.http.delete(`/v1/admin/users/${u.id}`).set(auth(admin.token)).expect(204);
    await ctx.http.get('/v1/me').set(auth(u.token)).expect(401);
    expect(await ctx.db.one('SELECT id FROM users WHERE id = $1', [u.id])).toBeNull();
    expect((await ctx.db.one('SELECT count(*)::int AS n FROM playlists WHERE owner_id = $1', [u.id])).n).toBe(0);
    await ctx.http.delete(`/v1/admin/users/${u.id}`).set(auth(admin.token)).expect(404);

    const audit = await ctx.http.get('/v1/admin/audit-logs').query({ action: 'user.admin_' }).set(auth(admin.token)).expect(200);
    const actions = new Set(audit.body.items.map((a: any) => a.action));
    for (const a of ['user.admin_create', 'user.admin_update', 'user.admin_set_password', 'user.admin_send_reset', 'user.admin_delete']) expect(actions).toContain(a);
  });

  it('forbids self-deletion and deleting the last active admin', async () => {
    const self = await ctx.http.delete(`/v1/admin/users/${admin.id}`).set(auth(admin.token)).expect(409);
    expect(self.body.error.code).toBe('cannot_delete_self');
    const helper = await registerUser(ctx, 'admin');
    const victim = await registerUser(ctx, 'admin');
    await ctx.db.query(`UPDATE users SET role = 'user' WHERE role = 'admin' AND id NOT IN ($1, $2, $3)`, [admin.id, helper.id, victim.id]);
    await ctx.http.delete(`/v1/admin/users/${victim.id}`).set(auth(helper.token)).expect(204);
    // Over HTTP the acting admin is itself active, so the "last admin" case can only arise through a race
    // or a disabled actor; exercise the shared deletion path directly with `admin` as the last active admin.
    await ctx.db.query('UPDATE users SET disabled_at = now() WHERE id = $1', [helper.id]);
    const { UsersService } = await import('../../src/users/users.service.js');
    const users = ctx.app.get(UsersService);
    await expect(users.deleteAccount(admin.id, { actorId: helper.id })).rejects.toMatchObject({ code: 'last_admin' });
    // Demoting/disabling the last active admin is also refused.
    const res = await ctx.http.patch(`/v1/admin/users/${admin.id}`).set(auth(admin.token)).send({ disabled: true }).expect(409);
    expect(res.body.error.code).toBe('last_admin');
  });
});
