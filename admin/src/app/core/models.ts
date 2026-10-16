export interface PublicUser {
  id: string;
  username: string;
  email: string | null;
  role: 'USER' | 'MODERATOR' | 'ADMIN';
  status: string;
  emailVerified: boolean;
  isGuest: boolean;
  lastLoginAt: string | null;
  createdAt: string;
}

export interface LoginResponse {
  user: PublicUser;
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
}

export interface Session {
  user: PublicUser;
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export interface GameOption {
  key: string;
  name: string;
}

export interface SeriesRow {
  date: string;
  count: number;
  amount?: number;
}

export interface DashboardResponse {
  range: { from: string; to: string; gameKey: string | null };
  users: {
    total: number;
    guests: number;
    active: number;
    suspended: number;
    banned: number;
    registeredInRange: number;
    registrations: SeriesRow[];
  };
  matches: {
    activeNow: number;
    pendingNow: number;
    totalInRange: number;
    byStatus: Record<string, number>;
    humanVsHuman: number;
    humanVsAi: number;
    byGame: { gameKey: string; name: string; matches: number }[];
  };
  economy: {
    coinsCirculation: number;
    wallets: number;
    issuedInRange: number;
    spentInRange: number;
    transactionsInRange: number;
    byType: { type: string; count: number; amount: number }[];
    grantsPerDay: SeriesRow[];
  };
  health: {
    status: string;
    dbLatencyMs: number;
    uptimeSeconds: number;
    queueDepth: number;
    serverTime: string;
  };
  recent: {
    registrations: {
      id: string;
      username: string;
      isGuest: boolean;
      status: string;
      createdAt: string;
    }[];
    audit:
      | {
          id: string;
          action: string;
          targetType: string | null;
          targetId: string | null;
          createdAt: string;
          actor: { username: string } | null;
        }[]
      | null;
  };
}

// --- Phase C: user & account management --------------------------------------

export interface Paginated<T> {
  items: T[];
  page: number;
  limit: number;
  total: number;
}

export interface UserStats {
  wins: number;
  losses: number;
  draws: number;
  gamesPlayed: number;
  rating: number;
  level: number;
}

export interface AdminUser {
  id: string;
  username: string;
  email: string | null;
  role: 'USER' | 'MODERATOR' | 'ADMIN';
  status: 'ACTIVE' | 'SUSPENDED' | 'BANNED';
  isGuest: boolean;
  createdAt: string;
  lastLoginAt: string | null;
  stats: UserStats | null;
}

export interface ModerationNote {
  id: string;
  body: string;
  createdAt: string;
  author: { id: string; username: string };
}

export interface PlayerProfile {
  displayName: string | null;
  level: number;
  xp: number;
  rating: number;
  wins: number;
  losses: number;
  draws: number;
  gamesPlayed: number;
}

export interface PlayerDetail {
  id: string;
  username: string;
  email: string | null;
  role: 'USER' | 'MODERATOR' | 'ADMIN';
  status: 'ACTIVE' | 'SUSPENDED' | 'BANNED';
  isGuest: boolean;
  royalPassExpiresAt: string | null;
  lastLoginAt: string | null;
  createdAt: string;
  profile: PlayerProfile | null;
  wallets: { currency: string; balance: number; lockedBalance: number }[];
}

export interface WalletTx {
  id: string;
  amount: number;
  balanceAfter: number;
  type: string;
  memo: string | null;
  createdAt: string;
}

export interface WalletPage extends Paginated<WalletTx> {
  balance: number;
}

export interface MatchPlayerRow {
  userId: string;
  seat: number;
  result: string;
  score: number;
  user: { username: string };
}

export interface PlayerMatchRow {
  id: string;
  status: string;
  createdAt: string;
  completedAt: string | null;
  game: { key: string; name: string } | null;
  players: MatchPlayerRow[];
}

export interface AuditRow {
  id: string;
  action: string;
  actor: string;
  actorId: string;
  targetType: string | null;
  targetId: string | null;
  data: Record<string, unknown> | null;
  createdAt: string;
}

export interface SessionRevokeResult {
  userId: string;
  sessionsRevoked: number;
}

export interface RoleChangeResult {
  id: string;
  username: string;
  role: 'USER' | 'MODERATOR' | 'ADMIN';
  sessionsRevoked: number;
}
