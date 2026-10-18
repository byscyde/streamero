import { createParamDecorator, ExecutionContext, SetMetadata } from '@nestjs/common';
import type { AuthUser, Role } from './auth-user.js';

export const IS_PUBLIC = 'streamero:isPublic';
export const OPTIONAL_AUTH = 'streamero:optionalAuth';
export const REQUIRED_ROLE = 'streamero:role';

/** Endpoint does not require authentication. */
export const Public = () => SetMetadata(IS_PUBLIC, true);
/** Endpoint works anonymously but attaches the user when a valid token is present. */
export const OptionalAuth = () => SetMetadata(OPTIONAL_AUTH, true);
/** Minimum role required (roles are hierarchical: admin > editor > user). */
export const RequireRole = (role: Role) => SetMetadata(REQUIRED_ROLE, role);

export const CurrentUser = createParamDecorator((_: unknown, ctx: ExecutionContext): AuthUser | undefined => {
  return ctx.switchToHttp().getRequest().user;
});
