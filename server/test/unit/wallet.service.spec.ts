import { BadRequestException, UnprocessableEntityException } from '@nestjs/common';
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
    const result = await service.credit('u1', 50, { type: 'DEPOSIT' });

    expect(result.replayed).toBe(false);
    expect(result.wallet.balance).toBe(150);
    expect(tx.wallet.updateMany).toHaveBeenCalledWith(
      expect.objectContaining({ where: { id: 'w1', version: 1 } }),
    );
    expect(tx.walletTransaction.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({ amount: 50, balanceAfter: 150, type: 'DEPOSIT' }),
      }),
    );
  });

  it('rejects a debit that would overdraw the wallet', async () => {
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

    await expect(service.debit('u1', 50, { type: 'WAGER' })).rejects.toBeInstanceOf(
      UnprocessableEntityException,
    );
    expect(tx.wallet.updateMany).not.toHaveBeenCalled();
  });

  it('replays an idempotent operation without touching the wallet', async () => {
    const existing = { id: 't9', amount: 50, wallet: walletRow({ balance: 150 }) };
    const { service, prisma } = makeService({ findByIdempotency: existing });

    const result = await service.credit('u1', 50, {
      type: 'DAILY_REWARD',
      idempotencyKey: 'daily:u1:2026-10-05',
    });

    expect(result.replayed).toBe(true);
    expect(result.transaction.id).toBe('t9');
    expect(prisma.$transaction).not.toHaveBeenCalled();
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

    const result = await service.credit('u1', 50, { type: 'BONUS' });
    expect(result.replayed).toBe(false);
    expect(tx.wallet.updateMany).toHaveBeenCalledTimes(2);
  });

  it('rejects zero and non-integer amounts', async () => {
    const { service } = makeService({});
    await expect(service.credit('u1', 0, { type: 'BONUS' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.credit('u1', 1.5, { type: 'BONUS' })).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });
});
