import { randomUUID } from 'node:crypto';
import { HttpStatus, Inject, Injectable, Logger } from '@nestjs/common';
import { hash, verify } from '@node-rs/argon2';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import type pg from 'pg';
import { AuditService } from '../audit/audit.service.js';
import type { Role } from '../common/auth-user.js';
import { AppError, badRequest, conflict, unauthorized } from '../common/errors.js';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import { DbService } from '../db/db.service.js';
import { MailService } from '../mail/mail.service.js';
import { randomToken, sha256, TokensService } from './tokens.service.js';

const ARGON = { memoryCost: 19456, timeCost: 2, parallelism: 1 }; // OWASP argon2id baseline
// A real hash is verified even for unknown emails so login timing does not reveal whether an account exists.
let dummyHash: Promise<string> | undefined;
const getDummyHash = () => (dummyHash ??= hash('streamero-timing-equaliser', ARGON));

export interface SessionTokens {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  tokenType: 'Bearer';
  user: PublicUser;
}

export interface PublicUser {
  id: string;
  email: string;
  displayName: string;
  role: Role;
  emailVerified: boolean;
  avatarUrl: string | null;
}

const googleJwks = createRemoteJWKSet(new URL('https://www.googleapis.com/oauth2/v3/certs'));

@Injectable()
export class AuthService {
  private readonly logger = new Logger(AuthService.name);

  constructor(
    private readonly db: DbService,
    private readonly tokens: TokensService,
    private readonly mail: MailService,
    private readonly audit: AuditService,
    @Inject(APP_CONFIG) private readonly config: AppConfig,
  ) {}

  hashPassword(password: string) {
    return hash(password, ARGON);
  }

  async register(email: string, password: string, displayName: string, ua?: string, ip?: string): Promise<SessionTokens> {
    const passwordHash = await this.hashPassword(password);
    const user = await this.db.one(
      `INSERT INTO users (email, password_hash, display_name) VALUES ($1, $2, $3)
       ON CONFLICT (email) DO NOTHING RETURNING *`,
      [email.trim(), passwordHash, displayName.trim()],
    );
    if (!user) throw conflict('email_taken', 'An account with this email already exists');
    await this.audit.record({ actorId: user.id, action: 'auth.register', targetType: 'user', targetId: user.id, ip });
    await this.sendVerification(user.id, user.email);
    return this.issueSession(user, ua);
  }

  async login(email: string, password: string, ua?: string, ip?: string): Promise<SessionTokens> {
    const user = await this.db.one('SELECT * FROM users WHERE email = $1', [email.trim()]);
    const ok = await verify(user?.password_hash ?? (await getDummyHash()), password).catch(() => false);
    if (!user || !user.password_hash || !ok) {
      await this.audit.record({ actorId: user?.id ?? null, action: 'auth.login_failed', ip });
      throw unauthorized('invalid_credentials', 'Email or password is incorrect');
    }
    if (user.disabled_at) throw new AppError(HttpStatus.FORBIDDEN, 'account_disabled', 'This account is disabled');
    await this.audit.record({ actorId: user.id, action: 'auth.login', targetType: 'user', targetId: user.id, ip });
    return this.issueSession(user, ua);
  }

  async issueSession(user: any, ua?: string, familyId: string = randomUUID(), client?: pg.PoolClient): Promise<SessionTokens> {
    const access = await this.tokens.signAccess({ id: user.id, role: user.role });
    const refreshToken = randomToken(48);
    await this.db.query(
      `INSERT INTO refresh_tokens (user_id, family_id, token_hash, expires_at, user_agent)
       VALUES ($1, $2, $3, now() + make_interval(days => $4), $5)`,
      [user.id, familyId, sha256(refreshToken), this.config.REFRESH_TOKEN_TTL_DAYS, ua?.slice(0, 300) ?? null],
      client,
    );
    return { accessToken: access.token, refreshToken, expiresIn: access.expiresIn, tokenType: 'Bearer', user: toPublicUser(user) };
  }

  /**
   * Refresh-token rotation with reuse detection: each refresh token is single-use. Presenting a token
   * that was already rotated means it leaked, so the entire token family (all descendants) is revoked.
   */
  async refresh(refreshToken: string, ua?: string): Promise<SessionTokens> {
    const outcome = await this.db.tx(async (client) => {
      const row = await this.db.one(
        `SELECT rt.*, u.disabled_at FROM refresh_tokens rt JOIN users u ON u.id = rt.user_id
         WHERE rt.token_hash = $1 FOR UPDATE OF rt`,
        [sha256(refreshToken)],
        client,
      );
      if (!row) throw unauthorized('invalid_refresh_token', 'Refresh token is invalid');
      if (row.revoked_at) {
        // Revoke the whole family and commit *before* rejecting, so the revocation is not rolled back.
        await this.db.query('UPDATE refresh_tokens SET revoked_at = coalesce(revoked_at, now()) WHERE family_id = $1', [row.family_id], client);
        await this.audit.record({ actorId: row.user_id, action: 'auth.refresh_reuse_detected', targetId: row.family_id }, client);
        return { reused: true as const, userId: row.user_id };
      }
      if (new Date(row.expires_at) <= new Date()) throw unauthorized('refresh_token_expired', 'Session expired');
      if (row.disabled_at) throw new AppError(HttpStatus.FORBIDDEN, 'account_disabled', 'This account is disabled');
      const user = await this.db.one('SELECT * FROM users WHERE id = $1', [row.user_id], client);
      const session = await this.issueSession(user, ua ?? row.user_agent, row.family_id, client);
      await this.db.query(
        `UPDATE refresh_tokens SET revoked_at = now(),
           replaced_by = (SELECT id FROM refresh_tokens WHERE token_hash = $2) WHERE id = $1`,
        [row.id, sha256(session.refreshToken)],
        client,
      );
      return { reused: false as const, session };
    });
    if (outcome.reused) {
      this.logger.warn({ userId: outcome.userId }, 'Refresh token reuse detected; session family revoked');
      throw unauthorized('refresh_token_reused', 'Session was revoked for security reasons, please sign in again');
    }
    return outcome.session;
  }

  async logout(refreshToken: string) {
    await this.db.query(
      `UPDATE refresh_tokens SET revoked_at = now()
       WHERE family_id = (SELECT family_id FROM refresh_tokens WHERE token_hash = $1) AND revoked_at IS NULL`,
      [sha256(refreshToken)],
    );
  }

  async logoutAll(userId: string) {
    await this.db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId]);
  }

  private async createEmailToken(userId: string, purpose: 'verify_email' | 'reset_password', ttlMinutes: number) {
    const token = randomToken(32);
    await this.db.query('UPDATE email_tokens SET used_at = now() WHERE user_id = $1 AND purpose = $2 AND used_at IS NULL', [
      userId,
      purpose,
    ]);
    await this.db.query(
      `INSERT INTO email_tokens (user_id, purpose, token_hash, expires_at)
       VALUES ($1, $2, $3, now() + make_interval(mins => $4))`,
      [userId, purpose, sha256(token), ttlMinutes],
    );
    return token;
  }

  private async consumeEmailToken(token: string, purpose: 'verify_email' | 'reset_password', client: pg.PoolClient) {
    const row = await this.db.one(
      `UPDATE email_tokens SET used_at = now()
       WHERE token_hash = $1 AND purpose = $2 AND used_at IS NULL AND expires_at > now()
       RETURNING user_id`,
      [sha256(token), purpose],
      client,
    );
    if (!row) throw badRequest('invalid_token', 'This link is invalid or has expired');
    return row.user_id as string;
  }

  async sendVerification(userId: string, email: string) {
    const token = await this.createEmailToken(userId, 'verify_email', 60 * 24);
    await this.mail.send({
      to: email,
      subject: 'Verify your STREAMERO account',
      text: `Welcome to STREAMERO!\n\nConfirm your email address by opening this link (it opens in your web browser):\n${this.config.APP_LINK_BASE}verify-email?token=${token}\n\nThe link expires in 24 hours.`,
    });
  }

  async resendVerification(userId: string) {
    const user = await this.db.one('SELECT id, email, email_verified_at FROM users WHERE id = $1', [userId]);
    if (!user || user.email_verified_at) return;
    await this.sendVerification(user.id, user.email);
  }

  async verifyEmail(token: string) {
    await this.db.tx(async (client) => {
      const userId = await this.consumeEmailToken(token, 'verify_email', client);
      await this.db.query('UPDATE users SET email_verified_at = coalesce(email_verified_at, now()) WHERE id = $1', [userId], client);
    });
  }

  /** Always succeeds from the caller's perspective to avoid account enumeration. */
  async forgotPassword(email: string, ip?: string) {
    const user = await this.db.one('SELECT id, email FROM users WHERE email = $1 AND disabled_at IS NULL', [email.trim()]);
    if (!user) return;
    await this.audit.record({ actorId: user.id, action: 'auth.password_reset_requested', ip });
    await this.sendPasswordReset(user.id, user.email);
  }

  /**
   * Creates a single-use reset token and emails the link. Used by self-service "forgot password" and by
   * administrators (send-reset, or inviting a new account that has no password yet: `invite` = longer TTL).
   */
  async sendPasswordReset(userId: string, email: string, opts: { invite?: boolean } = {}) {
    const ttlMinutes = opts.invite ? 60 * 24 * 3 : 30;
    const token = await this.createEmailToken(userId, 'reset_password', ttlMinutes);
    const link = `${this.config.APP_LINK_BASE}reset-password?token=${token}`;
    await this.mail.send(
      opts.invite
        ? {
            to: email,
            subject: 'Your STREAMERO account is ready',
            text: `An administrator created a STREAMERO account for you (${email}).\n\nOpen this link to choose your password (it opens in your web browser):\n${link}\n\nThe link expires in 3 days.`,
          }
        : {
            to: email,
            subject: 'Reset your STREAMERO password',
            text: `Someone requested a password reset for your STREAMERO account.\n\nOpen this link to choose a new password (it opens in your web browser):\n${link}\n\nThe link expires in 30 minutes. If this wasn't you, ignore this email.`,
          },
    );
  }

  /** Sets a password without knowing the old one (admin action) and signs the user out everywhere. */
  async setPassword(userId: string, password: string, client?: pg.PoolClient) {
    await this.db.query('UPDATE users SET password_hash = $2 WHERE id = $1', [userId, await this.hashPassword(password)], client);
    await this.db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId], client);
  }

  async resetPassword(token: string, password: string, ip?: string) {
    const passwordHash = await this.hashPassword(password);
    await this.db.tx(async (client) => {
      const userId = await this.consumeEmailToken(token, 'reset_password', client);
      await this.db.query('UPDATE users SET password_hash = $2, email_verified_at = coalesce(email_verified_at, now()) WHERE id = $1', [userId, passwordHash], client);
      await this.db.query('UPDATE refresh_tokens SET revoked_at = now() WHERE user_id = $1 AND revoked_at IS NULL', [userId], client);
      await this.audit.record({ actorId: userId, action: 'auth.password_reset', ip }, client);
    });
  }

  async changePassword(userId: string, current: string, next: string) {
    const user = await this.db.one('SELECT password_hash FROM users WHERE id = $1', [userId]);
    if (!user?.password_hash || !(await verify(user.password_hash, current).catch(() => false))) {
      throw unauthorized('invalid_credentials', 'Current password is incorrect');
    }
    await this.db.query('UPDATE users SET password_hash = $2 WHERE id = $1', [userId, await this.hashPassword(next)]);
    await this.logoutAll(userId);
    await this.audit.record({ actorId: userId, action: 'auth.password_changed' });
  }

  /** Verifies a Google ID token against Google's published keys and links or creates the account. */
  async signInWithGoogle(idToken: string, nonce: string | undefined, ua?: string) {
    const audience = [this.config.GOOGLE_IOS_CLIENT_ID, this.config.GOOGLE_WEB_CLIENT_ID].filter(Boolean);
    if (audience.length === 0) {
      throw new AppError(HttpStatus.NOT_IMPLEMENTED, 'google_not_configured', 'Google sign-in is not configured on this server');
    }
    let payload: any;
    try {
      ({ payload } = await jwtVerify(idToken, googleJwks, { issuer: ['https://accounts.google.com', 'accounts.google.com'], audience }));
    } catch {
      throw unauthorized('invalid_google_token', 'Google ID token could not be verified');
    }
    if (nonce !== undefined && payload.nonce !== nonce) throw unauthorized('invalid_google_token', 'Nonce mismatch');
    const emailVerified = payload.email_verified === true || payload.email_verified === 'true';
    if (typeof payload.email !== 'string' || !emailVerified) {
      throw unauthorized('invalid_google_token', 'Google account has no verified email address');
    }
    const sub = String(payload.sub);
    const email = payload.email.toLowerCase();
    const displayName = typeof payload.name === 'string' && payload.name.trim() ? payload.name.trim().slice(0, 80) : email.split('@')[0];
    const user = await this.db.tx(async (client) => {
      const bySub = await this.db.one('SELECT * FROM users WHERE google_sub = $1', [sub], client);
      if (bySub) return bySub;
      // Google asserts the address is verified, so an existing email account is linked rather than duplicated.
      const byEmail = await this.db.one('SELECT * FROM users WHERE lower(email) = $1 FOR UPDATE', [email], client);
      if (byEmail) {
        return this.db.one(
          'UPDATE users SET google_sub = $2, email_verified_at = coalesce(email_verified_at, now()) WHERE id = $1 RETURNING *',
          [byEmail.id, sub],
          client,
        );
      }
      return this.db.one(
        'INSERT INTO users (email, display_name, google_sub, email_verified_at) VALUES ($1, $2, $3, now()) RETURNING *',
        [email, displayName, sub],
        client,
      );
    });
    if (user.disabled_at) throw new AppError(HttpStatus.FORBIDDEN, 'account_disabled', 'This account is disabled');
    return this.issueSession(user, ua);
  }
}

export function toPublicUser(u: any): PublicUser {
  return {
    id: u.id,
    email: u.email,
    displayName: u.display_name,
    role: u.role,
    emailVerified: !!u.email_verified_at,
    avatarUrl: u.avatar_asset_id ? `/v1/artwork/${u.avatar_asset_id}` : null,
  };
}
