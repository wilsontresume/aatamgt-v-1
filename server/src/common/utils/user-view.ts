import { User } from '@prisma/client';

export interface PublicUser {
  id: string;
  username: string;
  email: string | null;
  role: string;
  status: string;
  emailVerified: boolean;
  lastLoginAt: string | null;
  createdAt: string;
}

export function toPublicUser(user: User): PublicUser {
  return {
    id: user.id,
    username: user.username,
    email: user.email,
    role: user.role,
    status: user.status,
    emailVerified: user.emailVerified,
    lastLoginAt: user.lastLoginAt?.toISOString() ?? null,
    createdAt: user.createdAt.toISOString(),
  };
}
