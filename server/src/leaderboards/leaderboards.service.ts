import { Injectable } from '@nestjs/common';
import { PrismaService } from '../prisma/prisma.service';
import { LeaderboardPeriod } from '@prisma/client';

export const MAX_BOARD_SIZE = 100;

@Injectable()
export class LeaderboardsService {
  constructor(private readonly prisma: PrismaService) {}

  /**
   * Recomputes a leaderboard from authoritative data (profile ratings or
   * completed match results) and materialises it into leaderboard_entries.
   */
  async refresh(key: string, period: LeaderboardPeriod = 'ALL_TIME'): Promise<number> {
    const rows = key === 'global' ? await this.globalRows() : await this.gameRows(key);
    const ranked = rows
      .sort((a, b) => b.score - a.score || a.userId.localeCompare(b.userId))
      .slice(0, MAX_BOARD_SIZE);

    const now = new Date();
    await this.prisma.$transaction([
      this.prisma.leaderboardEntry.deleteMany({ where: { key, period } }),
      this.prisma.leaderboardEntry.createMany({
        data: ranked.map((row, index) => ({
          key,
          period,
          userId: row.userId,
          gameKey: key === 'global' ? null : key,
          score: row.score,
          rank: index + 1,
          updatedAt: now,
        })),
      }),
    ]);
    return ranked.length;
  }

  async get(key: string, period: LeaderboardPeriod = 'ALL_TIME') {
    const entries = await this.prisma.leaderboardEntry.findMany({
      where: { key, period },
      orderBy: { rank: 'asc' },
      take: MAX_BOARD_SIZE,
      include: { user: { select: { username: true } } },
    });
    return {
      key,
      period,
      updatedAt: entries[0]?.updatedAt.toISOString() ?? null,
      items: entries.map((entry) => ({
        rank: entry.rank,
        userId: entry.userId,
        username: entry.user.username,
        score: entry.score,
      })),
    };
  }

  private async globalRows(): Promise<{ userId: string; score: number }[]> {
    const profiles = await this.prisma.profile.findMany({
      where: { isPublic: true, user: { deletedAt: null } },
      select: { userId: true, rating: true },
      take: 500,
    });
    return profiles.map((p) => ({ userId: p.userId, score: p.rating }));
  }

  private async gameRows(gameKey: string): Promise<{ userId: string; score: number }[]> {
    const grouped = await this.prisma.matchPlayer.groupBy({
      by: ['userId'],
      where: {
        result: 'WIN',
        match: { gameKey, status: 'COMPLETED' },
      },
      _count: { _all: true },
    });
    return grouped.map((row) => ({ userId: row.userId, score: row._count._all }));
  }
}
