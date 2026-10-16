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
