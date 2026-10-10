import { ConflictException, ForbiddenException, UnauthorizedException } from '@nestjs/common';
import { AuthService } from '../../src/auth/auth.service';
import * as bcrypt from 'bcryptjs';

const cfg = {
  jwt: {
    accessSecret: 'a'.repeat(32),
    refreshSecret: 'b'.repeat(32),
    accessTtl: 900,
    refreshTtl: 2592000,
  },
  coins: {
    registrationBonus: 1000,
    dailyLoginBonus: 100,
    rewardedAdBonus: 500,
    rewardedAdStandard: 100,
  },
};

const baseUser = {
  id: 'u1',
  username: 'player1',
  email: 'player1@example.com',
  passwordHash: '',
  role: 'USER',
  status: 'ACTIVE',
  emailVerified: false,
  lastLoginAt: null,
  deletedAt: null,
  createdAt: new Date(),
  updatedAt: new Date(),
};

function makeAuth(
  overrides: {
    findFirst?: unknown;
    findUnique?: unknown;
    refreshToken?: Partial<Record<'findUnique' | 'create' | 'update' | 'deleteMany', jest.Mock>>;
  } = {},
) {
  const user = { ...baseUser, ...(overrides.findUnique as object) };
  const prisma = {
    user: {
      findFirst: jest.fn().mockResolvedValue(overrides.findFirst ?? null),
      findUnique: jest.fn().mockResolvedValue(user),
      create: jest.fn().mockResolvedValue(user),
      update: jest.fn().mockResolvedValue(user),
    },
    refreshToken: {
      findUnique: jest.fn().mockResolvedValue(overrides.refreshToken?.findUnique?.() ?? null),
      create: jest.fn().mockResolvedValue({ id: 'r1' }),
      update: jest.fn().mockResolvedValue({ id: 'r1' }),
      deleteMany: jest.fn().mockResolvedValue({ count: 0 }),
    },
    $transaction: jest.fn(async (fn: (tx: unknown) => Promise<unknown>) =>
      fn({
        user: {
          create: jest.fn(async (args: { data: Record<string, unknown> }) => ({
            ...baseUser,
            username: String(args.data.username ?? baseUser.username),
            email: (args.data.email as string | null) ?? baseUser.email,
            passwordHash: String(args.data.passwordHash ?? ''),
          })),
        },
      }),
    ),
  };

  const jwt = {
    signAsync: jest.fn().mockResolvedValue('signed-token'),
    verifyAsync: jest.fn().mockResolvedValue({ sub: 'u1', jti: 'jti-1' }),
  };
  const config = { get: jest.fn().mockReturnValue(cfg) };
  const wallet = {
    credit: jest.fn().mockResolvedValue({
      transaction: { id: 'tb-1' },
      wallet: { balance: 1000 },
      replayed: false,
    }),
  };
  const service = new AuthService(
    prisma as never,
    jwt as never,
    config as never,
    wallet as never,
    { number: jest.fn().mockResolvedValue(1000) } as never,
  );
  return { service, prisma, jwt, user, wallet };
}

describe('AuthService', () => {
  it('registers a user with a hashed password (never plaintext)', async () => {
    const { service, prisma } = makeAuth();
    const { user, tokens } = await service.register({
      username: 'Player1',
      password: 'super-secret-1',
    });

    expect(user.passwordHash).not.toContain('super-secret-1');
    expect(await bcrypt.compare('super-secret-1', user.passwordHash)).toBe(true);
    expect(tokens.accessToken).toBe('signed-token');
    expect(prisma.refreshToken.create).toHaveBeenCalled();
  });

  it('grants the configured registration bonus exactly once via the ledger', async () => {
    const { service, wallet } = makeAuth();
    await service.register({ username: 'Player1', password: 'super-secret-1' });

    expect(wallet.credit).toHaveBeenCalledTimes(1);
    expect(wallet.credit).toHaveBeenCalledWith(
      expect.any(String),
      1000,
      expect.objectContaining({
        type: 'REGISTRATION_BONUS',
        idempotencyKey: expect.stringMatching(/^registration:/),
      }),
    );
  });

  it('rejects a duplicate username', async () => {
    const { service } = makeAuth({ findFirst: { ...baseUser, username: 'player1' } });
    await expect(
      service.register({ username: 'player1', password: 'super-secret-1' }),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('logs in with valid credentials', async () => {
    const passwordHash = await bcrypt.hash('correct-horse', 4);
    const { service, prisma } = makeAuth({
      findFirst: { ...baseUser, passwordHash },
    });
    const { tokens } = await service.login({ identifier: 'Player1', password: 'correct-horse' });
    expect(tokens.accessToken).toBe('signed-token');
    expect(prisma.user.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: { lastLoginAt: expect.any(Date) } }),
    );
  });

  it('rejects a wrong password without revealing the account', async () => {
    const passwordHash = await bcrypt.hash('correct-horse', 4);
    const { service } = makeAuth({ findFirst: { ...baseUser, passwordHash } });
    await expect(
      service.login({ identifier: 'player1', password: 'wrong' }),
    ).rejects.toBeInstanceOf(UnauthorizedException);
  });

  it('blocks suspended accounts from logging in', async () => {
    const passwordHash = await bcrypt.hash('correct-horse', 4);
    const { service } = makeAuth({
      findFirst: { ...baseUser, passwordHash, status: 'SUSPENDED' },
    });
    await expect(
      service.login({ identifier: 'player1', password: 'correct-horse' }),
    ).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects a revoked refresh token', async () => {
    const { service } = makeAuth({
      refreshToken: {
        findUnique: jest.fn().mockReturnValue({
          tokenHash: 'x',
          revokedAt: new Date(),
          expiresAt: new Date(Date.now() + 60_000),
        }),
      },
    });
    await expect(service.refresh('some-refresh-token')).rejects.toBeInstanceOf(
      UnauthorizedException,
    );
  });

  it('rotates a valid refresh token into a new pair', async () => {
    const { service, prisma } = makeAuth({
      refreshToken: {
        findUnique: jest.fn().mockResolvedValue({
          tokenHash: 'x',
          revokedAt: null,
          expiresAt: new Date(Date.now() + 60_000),
        }),
      },
    });
    const { tokens } = await service.refresh('some-refresh-token');
    expect(tokens.accessToken).toBe('signed-token');
    expect(prisma.refreshToken.update).toHaveBeenCalledWith(
      expect.objectContaining({ data: { revokedAt: expect.any(Date) } }),
    );
  });
});
