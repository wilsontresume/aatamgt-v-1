import { BadRequestException, UnprocessableEntityException } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { WalletService } from '../../src/wallet/wallet.service';

type Tx = {
  wallet: {
    findUnique: jest.Mock;
    updateMany: jest.Mock;
    findUniqueOrThrow: jest.Mock;
  };
  walletTransaction: { create: jest.Mock };
};

const walletRow = (overrides: Record<string, unknown> = {}) => ({
  id: 'w1',
  userId: 'u1',
  currency: 'COIN',
  balance: 100,
  lockedBalance: 0,
  version: 1,
  ...overrides,
});

function makeService(opts: {
  tx?: Partial<Tx>;
  findByIdempotency?: unknown;
  transactionImpl?: (fn: (tx: Tx) => Promise<unknown>) => Promise<unknown>;
}) {
  const tx: Tx = {
    wallet: {
      findUnique: jest.fn().mockResolvedValue(walletRow()),
      updateMany: jest.fn().mockResolvedValue({ count: 1 }),
      findUniqueOrThrow: jest.fn().mockResolvedValue(walletRow({ balance: 150, version: 2 })),
      ...(opts.tx?.wallet ?? {}),
    },
    walletTransaction: {
      create: jest.fn().mockResolvedValue({ id: 't1', amount: 50, balanceAfter: 150 }),
      ...(opts.tx?.walletTransaction ?? {}),
    },
  };

  const prisma = {
    wallet: { findUnique: jest.fn(), create: jest.fn() },
    walletTransaction: {
      findUnique: jest.fn().mockResolvedValue(opts.findByIdempotency ?? null),
    },
    $transaction: jest.fn(
      opts.transactionImpl ?? (async (fn: (t: Tx) => Promise<unknown>) => fn(tx)),
    ),
  };

  return { service: new WalletService(prisma as never), prisma, tx };
}

describe('WalletService', () => {
  it('applies a credit atomically and returns the new balance', async () => {
    const { service, tx } = makeService({});
    const result = await service.credit('u1', 50, { type: 'REGISTRATION_BONUS' });

    expect(result.replayed).toBe(false);
    expect(result.wallet.balance).toBe(150);
    expect(tx.wallet.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: 'w1', version: 1 } }),
    );
    expect(tx.walletTransaction.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ amount: 50, balanceAfter: 150, type: 'REGISTRATION_BONUS' }),
      }),
    );
  });

  it('rejects a debit that would push the balance negative', async () => {
    const tx: Tx = {
      wallet: {
        findUnique: jest.fn().mockResolvedValue(walletRow({ balance: 10 })),
        updateMany: jest.fn(),
        findUniqueOrThrow: jest.fn(),
      },
      walletTransaction: { create: jest.fn() },
    };
    const service = new WalletService({
      $transaction: jest.fn(async (fn: (t: Tx) => Promise<unknown>) => fn(tx)),
      walletTransaction: { findUnique: jest.fn().mockResolvedValue(null) },
    } as never);

    await expect(service.debit('u1', 50, { type: 'PURCHASE' })).rejects.toBeInstanceOf(
      UnprocessableEntityException,
    );
    expect(tx.wallet.updateMany).not.toHaveBeenCalled();
    expect(tx.walletTransaction.create).not.toHaveBeenCalled();
  });

  it('replays an idempotent operation without touching the wallet', async () => {
    const existing = { id: 't9', amount: 50, wallet: walletRow({ balance: 150 }) };
    const { service, prisma } = makeService({ findByIdempotency: existing });

    const result = await service.credit('u1', 50, {
      type: 'DAILY_LOGIN',
      idempotencyKey: 'daily:u1:2026-10-05',
    });

    expect(result.replayed).toBe(true);
    expect(result.transaction.id).toBe('t9');
    expect(prisma.$transaction).not.toHaveBeenCalled();
  });

  it('replays instead of failing when two identical keys race to insert', async () => {
    const winner = {
      id: 't-race',
      amount: 500,
      wallet: walletRow({ balance: 500, version: 1 }),
    };
    const p2002 = new Prisma.PrismaClientKnownRequestError('Unique constraint failed on idempotencyKey', {
      code: 'P2002',
      clientVersion: 'test',
    });
    const prisma = {
      wallet: { findUnique: jest.fn(), create: jest.fn() },
      walletTransaction: {
        findUnique: jest.fn().mockResolvedValueOnce(null).mockResolvedValue(winner),
      },
      $transaction: jest.fn().mockRejectedValue(p2002),
    };
    const service = new WalletService(prisma as never);

    const result = await service.credit('u1', 500, {
      type: 'REWARDED_AD',
      idempotencyKey: 'ad:u1:view-001',
    });

    expect(result.replayed).toBe(true);
    expect(result.transaction.id).toBe('t-race');
  });

  it('retries when the wallet version moved underneath it', async () => {
    const tx: Tx = {
      wallet: {
        findUnique: jest
          .fn()
          .mockResolvedValueOnce(walletRow({ version: 1 }))
          .mockResolvedValueOnce(walletRow({ version: 2, balance: 100 })),
        updateMany: jest
          .fn()
          .mockResolvedValueOnce({ count: 0 })
          .mockResolvedValueOnce({ count: 1 }),
        findUniqueOrThrow: jest.fn().mockResolvedValue(walletRow({ balance: 150, version: 3 })),
      },
      walletTransaction: {
        create: jest.fn().mockResolvedValue({ id: 't2', amount: 50, balanceAfter: 150 }),
      },
    };
    const service = new WalletService({
      $transaction: jest.fn(async (fn: (t: Tx) => Promise<unknown>) => fn(tx)),
      walletTransaction: { findUnique: jest.fn().mockResolvedValue(null) },
    } as never);

    const result = await service.credit('u1', 50, { type: 'MATCH_REWARD' });
    expect(result.replayed).toBe(false);
    expect(tx.wallet.updateMany).toHaveBeenCalledTimes(2);
  });

  it('rejects zero and non-integer amounts', async () => {
    const { service } = makeService({});
    await expect(service.credit('u1', 0, { type: 'MATCH_REWARD' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.credit('u1', 1.5, { type: 'MATCH_REWARD' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.credit('u1', -50, { type: 'MATCH_REWARD' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  describe('verifyIntegrity', () => {
    function integrityService(
      balance: number,
      rows: Array<{ id: string; amount: number; balanceAfter: number }>,
    ) {
      const prisma = {
        wallet: {
          findUnique: jest.fn().mockResolvedValue(walletRow({ balance })),
          create: jest.fn(),
        },
        walletTransaction: { findMany: jest.fn().mockResolvedValue(rows) },
      };
      return new WalletService(prisma as never);
    }

    it('accepts a wallet whose ledger chains to its balance', async () => {
      const service = integrityService(1500, [
        { id: 't1', amount: 1000, balanceAfter: 1000 },
        { id: 't2', amount: 100, balanceAfter: 1100 },
        { id: 't3', amount: 500, balanceAfter: 1600 },
        { id: 't4', amount: -100, balanceAfter: 1500 },
      ]);
      const report = await service.verifyIntegrity('u1');
      expect(report.ok).toBe(true);
      expect(report.issues).toEqual([]);
      expect(report.ledgerSum).toBe(1500);
      expect(report.transactionCount).toBe(4);
    });

    it('accepts a brand-new wallet with an empty ledger', async () => {
      const service = integrityService(0, []);
      const report = await service.verifyIntegrity('u1');
      expect(report.ok).toBe(true);
      expect(report.ledgerSum).toBe(0);
    });

    it('flags a balance that drifted from the ledger', async () => {
      const service = integrityService(9999, [
        { id: 't1', amount: 1000, balanceAfter: 1000 },
      ]);
      const report = await service.verifyIntegrity('u1');
      expect(report.ok).toBe(false);
      expect(report.issues.join(' ')).toContain('wallet balance is 9999');
    });

    it('flags a broken balanceAfter chain', async () => {
      const service = integrityService(600, [
        { id: 't1', amount: 1000, balanceAfter: 1000 },
        { id: 't2', amount: 100, balanceAfter: 9999 },
        { id: 't3', amount: -500, balanceAfter: 600 },
      ]);
      const report = await service.verifyIntegrity('u1');
      expect(report.ok).toBe(false);
      expect(report.issues.join(' ')).toContain('ledger chain break');
    });

    it('flags a negative balance', async () => {
      const service = integrityService(-5, [
        { id: 't1', amount: -5, balanceAfter: -5 },
      ]);
      const report = await service.verifyIntegrity('u1');
      expect(report.ok).toBe(false);
      expect(report.issues.join(' ')).toContain('negative');
    });
  });
});
