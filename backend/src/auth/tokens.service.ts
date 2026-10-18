import { createHash, randomBytes } from 'node:crypto';
import { Inject, Injectable } from '@nestjs/common';
import { jwtVerify, SignJWT } from 'jose';
import { APP_CONFIG, type AppConfig } from '../config/config.js';
import type { AuthUser, Role } from '../common/auth-user.js';

export const sha256 = (v: string) => createHash('sha256').update(v).digest('hex');
export const randomToken = (bytes = 32) => randomBytes(bytes).toString('base64url');

@Injectable()
export class TokensService {
  private readonly key: Uint8Array;
  constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {
    this.key = new TextEncoder().encode(config.JWT_ACCESS_SECRET);
  }

  async signAccess(user: AuthUser): Promise<{ token: string; expiresIn: number }> {
    const expiresIn = this.config.ACCESS_TOKEN_TTL_SECONDS;
    const token = await new SignJWT({ role: user.role, typ: 'access' })
      .setProtectedHeader({ alg: 'HS256' })
      .setSubject(user.id)
      .setIssuer('streamero')
      .setAudience('streamero-api')
      .setIssuedAt()
      .setExpirationTime(`${expiresIn}s`)
      .sign(this.key);
    return { token, expiresIn };
  }

  async verifyAccess(token: string): Promise<AuthUser | null> {
    try {
      const { payload } = await jwtVerify(token, this.key, {
        issuer: 'streamero',
        audience: 'streamero-api',
        algorithms: ['HS256'],
      });
      if (payload.typ !== 'access' || typeof payload.sub !== 'string') return null;
      return { id: payload.sub, role: payload.role as Role };
    } catch {
      return null;
    }
  }
}
