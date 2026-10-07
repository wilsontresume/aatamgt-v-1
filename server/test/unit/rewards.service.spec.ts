import { BadRequestException, ConflictException } from '@nestjs/common';
import { RewardsService } from '../../src/rewards/rewards.service';

const coinsConfig = {
  coins: {
    registrationBonus: 1000,
    dailyLoginBonus: 100,
    rewardedAdBonus: 500,
    rewardedAdStandard: 100,
  },
};
const config = { get: jest.fn().mockReturnValue(coinsConfig) };

function makeRewards(opts: {
  claimedToday?: unknown;
  lastClaim?: unknown;
  createResult?: unknown;
  creditResult?: unknown;
}) {
  const daily = {
    findUnique: jest.fn().mockResolvedValue(opts.claimedToday ?? null),
    findFirst: jest.fn().mockResolvedValue(opts.lastClaim ?? null),
    create: jest
      .fn()
      .mockResolvedValue(
        opts.createResult ?? { claimedAt: new Date(), streakDay: 1, rewardCoins: 100 },
      ),
  };
  const prisma = { dailyReward: daily };
  const wallet = {
    credit: jest
      .fn()
      .mockImplementation((_userId: string, amount: number) =>
        Promise.resolve(
          opts.creditResult ?? {
            transaction: { id: 't1', amount },
            wallet: { balance: amount },
            replayed: false,
          },
        ),
      ),
  };
  const notifications = { notify: jest.fn().mockResolvedValue(undefined) };
  const service = new RewardsService(
    prisma as never,
    wallet as never,
    notifications as never,
    config as never,
  );
  return { service, wallet, notifications, daily };
}

const yesterday = (): Date => {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - 86_400_000);
};

describe('RewardsService — daily login', () => {
  it('claims day one at the configured amount and credits exactly once', async () => {
    const { service, wallet, notifications } = makeRewards({});
    const result = await service.claim('u1');

    expect(result.streakDay).toBe(1);
    expect(result.coins).toBe(100);
    expect(wallet.credit).toHaveBeenCalledWith(
      'u1',
      100,
      expect.objectContaining({ type: 'DAILY_LOGIN', idempotencyKey: expect.any(String) }),
    );
    expect(notifications.notify).toHaveBeenCalled();
  });

  it('continues an unbroken streak at the configured amount', async () => {
    const { service } = makeRewards({
      lastClaim: { rewardDate: yesterday(), streakDay: 3 },
      createResult: { claimedAt: new Date(), streakDay: 4, rewardCoins: 100 },
    });
    const result = await service.claim('u1');
    expect(result.streakDay).toBe(4);
    expect(result.coins).toBe(100);
  });

  it('resets the streak after a missed day', async () => {
    const twoDaysAgo = new Date(yesterday().getTime() - 86_400_000);
    const { service } = makeRewards({
      lastClaim: { rewardDate: twoDaysAgo, streakDay: 9 },
      createResult: { claimedAt: new Date(), streakDay: 1, rewardCoins: 100 },
    });
    const result = await service.claim('u1');
    expect(result.streakDay).toBe(1);
  });

  it('refuses a second claim for the same day without touching the wallet', async () => {
    const { service, wallet } = makeRewards({
      claimedToday: { streakDay: 2, rewardCoins: 100 },
    });
    await expect(service.claim('u1')).rejects.toBeInstanceOf(ConflictException);
    expect(wallet.credit).not.toHaveBeenCalled();
  });

  it('advertises the configured amount in the status payload', async () => {
    const { service } = makeRewards({});
    const status = await service.status('u1');
    expect(status.nextRewardCoins).toBe(100);
    expect(status.todayClaimed).toBe(false);
  });
});

describe('RewardsService — rewarded ads (no SDK yet)', () => {
  it('credits the configured BONUS tier amount with a unique key', async () => {
    const { service, wallet, notifications } = makeRewards({});
    const result = await service.claimRewardedAd('u1', 'BONUS', 'view-000001');

    expect(result.coins).toBe(500);
    expect(result.replayed).toBe(false);
    expect(wallet.credit).toHaveBeenCalledWith(
      'u1',
      500,
      expect.objectContaining({
        type: 'REWARDED_AD',
        refId: 'BONUS',
        idempotencyKey: 'ad:u1:view-000001',
      }),
    );
    expect(notifications.notify).toHaveBeenCalledTimes(1);
  });

  it('credits the configured STANDARD tier amount', async () => {
    const { service, wallet } = makeRewards({});
    const result = await service.claimRewardedAd('u1', 'STANDARD', 'view-000002');

    expect(result.coins).toBe(100);
    expect(wallet.credit).toHaveBeenCalledWith(
      'u1',
      100,
      expect.objectContaining({ type: 'REWARDED_AD', refId: 'STANDARD' }),
    );
  });

  it('returns the original transaction on replay and does not notify again', async () => {
    const { service, wallet, notifications } = makeRewards({
      creditResult: {
        transaction: { id: 't-original', amount: 500 },
        wallet: { balance: 500 },
        replayed: true,
      },
    });
    const result = await service.claimRewardedAd('u1', 'BONUS', 'view-000001');

    expect(result.replayed).toBe(true);
    expect(result.transactionId).toBe('t-original');
    expect(notifications.notify).not.toHaveBeenCalled();
  });

  it('rejects an unknown tier', async () => {
    const { service } = makeRewards({});
    await expect(service.claimRewardedAd('u1', 'MEGA', 'view-000003')).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('rejects a malformed idempotency key', async () => {
    const { service } = makeRewards({});
    await expect(service.claimRewardedAd('u1', 'BONUS', 'short')).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.claimRewardedAd('u1', 'BONUS', 'bad key with spaces')).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });
});
