export type Role = 'user' | 'editor' | 'admin';

export interface AuthUser {
  id: string;
  role: Role;
}

const RANK: Record<Role, number> = { user: 0, editor: 1, admin: 2 };

export function hasRole(user: AuthUser | undefined, required: Role): boolean {
  return !!user && RANK[user.role] >= RANK[required];
}
