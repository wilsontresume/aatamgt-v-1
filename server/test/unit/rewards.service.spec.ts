import { ConflictException } from '@nestjs/common';
import {
  RewardsService,
  rewardCoinsForStreak,
  BASE_REWARD_COINS,
} from '../../src/rewards/rewards.service';

describe('rewardCoinsForStreak', () => {
  it('starts at the base reward', () => {
    expect(rewardCoinsForStreak(1)).toBe(BASE_REWARD_COINS);
  });

  it('grows by the step per consecutive day', () => {
    expect(rewardCoinsForStreak(2)).toBe(60);
    expect(rewardCoinsForStreak(3)).toBe(70);
  });

  it('caps the bonus after the maximum streak window', () => {
    expect(rewardCoinsForStreak(7)).toBe(110);
    expect(rewardCoinsForStreak(50)).toBe(110);
  });

  it('never pays less than the base reward', () => {
    expect(rewardCoinsForStreak(0)).toBe(BASE_REWARD_COINS);
  });
});

function makeRewards(opts: {
  claimedToday?: unknown;
  lastClaim?: unknown;
  createResult?: unknown;
}) {
  const daily = {
    findUnique: jest.fn().mockResolvedValue(opts.claimedToday ?? null),
    findFirst: jest.fn().mockResolvedValue(opts.lastClaim ?? null),
    create: jest
      .fn()
      .mockResolvedValue(
        opts.createResult ?? { claimedAt: new Date(), streakDay: 1, rewardCoins: 50 },
      ),
  };
  const prisma = { dailyReward: daily };
  const wallet = {
    credit: jest.fn().mockResolvedValue({
      transaction: { id: 't1' },
      wallet: { balance: 150 },
      replayed: false,
    }),
  };
  const notifications = { notify: jest.fn().mockResolvedValue(undefined) };
  const service = new RewardsService(prisma as never, wallet as never, notifications as never);
  return { service, wallet, notifications, daily };
}

const yesterday = (): Date => {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()) - 86_400_000);
};

describe('RewardsService', () => {
  it('claims day one and credits the wallet exactly once', async () => {
    const { service, wallet, notifications } = makeRewards({});
    const result = await service.claim('u1');

    expect(result.streakDay).toBe(1);
    expect(result.coins).toBe(50);
    expect(wallet.credit).toHaveBeenCalledWith(
      'u1',
      50,
      expect.objectContaining({ type: 'DAILY_REWARD', idempotencyKey: expect.any(String) }),
    );
    expect(notifications.notify).toHaveBeenCalled();
  });

  it('continues an unbroken streak', async () => {
    const { service } = makeRewards({
      lastClaim: { rewardDate: yesterday(), streakDay: 3 },
      createResult: { claimedAt: new Date(), streakDay: 4, rewardCoins: 80 },
    });
    const result = await service.claim('u1');
    expect(result.streakDay).toBe(4);
    expect(result.coins).toBe(80);
  });

  it('resets the streak after a missed day', async () => {
    const twoDaysAgo = new Date(yesterday().getTime() - 86_400_000);
    const { service } = makeRewards({
      lastClaim: { rewardDate: twoDaysAgo, streakDay: 9 },
      createResult: { claimedAt: new Date(), streakDay: 1, rewardCoins: 50 },
    });
    const result = await service.claim('u1');
    expect(result.streakDay).toBe(1);
  });

  it('refuses a second claim for the same day', async () => {
    const { service, wallet } = makeRewards({
      claimedToday: { streakDay: 2, rewardCoins: 60 },
    });
    await expect(service.claim('u1')).rejects.toBeInstanceOf(ConflictException);
    expect(wallet.credit).not.toHaveBeenCalled();
  });
});
