import { ConflictException, Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { WalletService } from '../wallet/wallet.service';
import { NotificationsService } from '../notifications/notifications.service';
import { SystemConfigService } from '../config/system-config.service';
import { Prisma } from '@prisma/client';

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
    private readonly systemConfig: SystemConfigService,
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
      nextRewardCoins: await this.systemConfig.number('coins.daily_reward'),
      nextStreakDay: nextStreak,
    };
  }

  /**
   * Daily login grant: one claim per UTC day, amount comes from server
   * config (COINS_DAILY_LOGIN_BONUS, default 100). Duplicate claims are
   * rejected by the unique (userId, rewardDate) constraint and the credit
   * itself is idempotent, so a retry can never double-pay.
   */
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
    const coins = await this.systemConfig.number('coins.daily_reward');
    const dateKey = today.toISOString().slice(0, 10);

    const result = await this.wallet.credit(userId, coins, {
      type: 'DAILY_LOGIN',
      refType: 'daily_login',
      refId: `${userId}:${dateKey}`,
      idempotencyKey: `daily:${userId}:${dateKey}`,
      memo: `Daily login bonus (day ${streakDay})`,
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
