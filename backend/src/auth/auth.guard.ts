import { CanActivate, ExecutionContext, Injectable } from '@nestjs/common';
import { Reflector } from '@nestjs/core';
import { hasRole, type Role } from '../common/auth-user.js';
import { IS_PUBLIC, OPTIONAL_AUTH, REQUIRED_ROLE } from '../common/decorators.js';
import { forbidden, unauthorized } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { TokensService } from './tokens.service.js';

/**
 * Global guard: every route requires a valid access token unless marked @Public().
 * The user row is re-checked so disabled or deleted accounts lose access immediately,
 * and the role comes from the database rather than the (possibly stale) token claim.
 */
@Injectable()
export class AuthGuard implements CanActivate {
  constructor(
    private readonly reflector: Reflector,
    private readonly tokens: TokensService,
    private readonly db: DbService,
  ) {}

  async canActivate(ctx: ExecutionContext): Promise<boolean> {
    const targets = [ctx.getHandler(), ctx.getClass()];
    const isPublic = this.reflector.getAllAndOverride<boolean>(IS_PUBLIC, targets);
    const optional = this.reflector.getAllAndOverride<boolean>(OPTIONAL_AUTH, targets);
    const role = this.reflector.getAllAndOverride<Role>(REQUIRED_ROLE, targets);
    const req = ctx.switchToHttp().getRequest();

    const header: string | undefined = req.headers['authorization'];
    const token = header?.startsWith('Bearer ') ? header.slice(7) : undefined;
    if (token) {
      const claims = await this.tokens.verifyAccess(token);
      if (claims) {
        const row = await this.db.one<{ id: string; role: Role }>(
          'SELECT id, role FROM users WHERE id = $1 AND disabled_at IS NULL',
          [claims.id],
        );
        if (row) req.user = { id: row.id, role: row.role };
      } else if (!isPublic && !optional) {
        throw unauthorized('invalid_token', 'Access token is invalid or expired');
      }
    }

    if (isPublic || optional) return true;
    if (!req.user) throw unauthorized();
    if (role && !hasRole(req.user, role)) throw forbidden('Insufficient role');
    return true;
  }
}
