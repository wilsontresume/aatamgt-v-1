import { ConflictException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { NotificationsService } from '../notifications/notifications.service';
import { Prisma } from '@prisma/client';

export const BASE_REWARD_COINS = 50;
export const REWARD_STEP_COINS = 10;
export const MAX_STREAK_DAYS = 7;

export function rewardCoinsForStreak(streakDay: number): number {
  const bonusDays = Math.min(Math.max(streakDay, 1) - 1, MAX_STREAK_DAYS - 1);
  return BASE_REWARD_COINS + bonusDays * REWARD_STEP_COINS;
}

function utcToday(): Date {
  const now = new Date();
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
}

function previousDay(date: Date): Date {
  return new Date(date.getTime() - 24 * 60 * 60 * 1000);
}

@Injectable()
export class RewardsService {
  constructor(
    private readonly prisma: PrismaService,
    private readonly wallet: WalletService,
    private readonly notifications: NotificationsService,
  ) {}

  async status(userId: string) {
    const today = utcToday();
    const claimedToday = await this.prisma.dailyReward.findUnique({
      where: { userId_rewardDate: { userId, rewardDate: today } },
    });
    const last = await this.prisma.dailyReward.findFirst({
      where: { userId, rewardDate: { lt: today } },
      orderBy: { rewardDate: 'desc' },
    });
    const yesterdayStreak =
      last && last.rewardDate.getTime() === previousDay(today).getTime() ? last.streakDay : 0;
    const nextStreak = claimedToday ? claimedToday.streakDay : yesterdayStreak + 1;

    return {
      todayClaimed: Boolean(claimedToday),
      currentStreak: claimedToday ? claimedToday.streakDay : yesterdayStreak,
      nextRewardCoins: rewardCoinsForStreak(nextStreak),
      nextStreakDay: nextStreak,
    };
  }

  async claim(userId: string) {
    const today = utcToday();
    const existing = await this.prisma.dailyReward.findUnique({
      where: { userId_rewardDate: { userId, rewardDate: today } },
    });
    if (existing) throw new ConflictException('Daily reward already claimed today');

    const last = await this.prisma.dailyReward.findFirst({
      where: { userId, rewardDate: { lt: today } },
      orderBy: { rewardDate: 'desc' },
    });
    const streakDay =
      last && last.rewardDate.getTime() === previousDay(today).getTime() ? last.streakDay + 1 : 1;
    const coins = rewardCoinsForStreak(streakDay);
    const dateKey = today.toISOString().slice(0, 10);

    const result = await this.wallet.credit(userId, coins, {
      type: 'DAILY_REWARD',
      refType: 'daily_reward',
      refId: `${userId}:${dateKey}`,
      idempotencyKey: `daily:${userId}:${dateKey}`,
      memo: `Daily reward day ${streakDay}`,
    });

    let row;
    try {
      row = await this.prisma.dailyReward.create({
        data: { userId, rewardDate: today, streakDay, rewardCoins: coins },
      });
    } catch (error) {
      if (error instanceof Prisma.PrismaClientKnownRequestError && error.code === 'P2002') {
        throw new ConflictException('Daily reward already claimed today');
      }
      throw error;
    }

    await this.notifications.notify({
      userId,
      type: 'daily_reward',
      title: 'Daily reward claimed',
      body: `You received ${coins} coins (day ${streakDay}).`,
      data: { coins, streakDay, transactionId: result.transaction.id },
    });

    return {
      claimedAt: row.claimedAt.toISOString(),
      coins,
      streakDay,
      balance: result.wallet.balance,
    };
  }
}
