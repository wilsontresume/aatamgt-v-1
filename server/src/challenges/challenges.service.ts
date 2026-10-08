import {
  BadRequestException,
  ConflictException,
  ForbiddenException,
  HttpException,
  Injectable,
  NotFoundException,
} from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Challenge, ChallengeStatus, Prisma } from '@prisma/client';
import { randomInt } from 'node:crypto';
import { PrismaService } from '../prisma/prisma.service';
import { GamesService } from '../games/games.service';
import { MatchesService } from '../matches/matches.service';
import { NotificationsService } from '../notifications/notifications.service';
import { AppConfig } from '../config/configuration';

/** Unambiguous alphabet: no 0/O, 1/I/L. 8 chars ≈ 40 bits — not enumerable. */
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
const CODE_LENGTH = 8;
const CODE_PATTERN = /^[A-Z0-9]{4,16}$/;

const CHALLENGE_INCLUDE = {
  challenger: { select: { id: true, username: true } },
  invitee: { select: { id: true, username: true } },
} satisfies Prisma.ChallengeInclude;

type ChallengeWithUsers = Challenge & {
  challenger: { id: string; username: string };
  invitee: { id: string; username: string } | null;
};

export interface CreateChallengeInput {
  gameKey: string;
  inviteeUsername?: string;
}

@Injectable()
export class ChallengesService {
  private readonly social: AppConfig['social'];

  constructor(
    private readonly prisma: PrismaService,
    config: ConfigService,
    private readonly games: GamesService,
    private readonly matches: MatchesService,
    private readonly notifications: NotificationsService,
  ) {
    this.social = (config.get<AppConfig>('app') as AppConfig).social;
  }

  // -------------------------------------------------------------------------
  // Commands
  // -------------------------------------------------------------------------

  async create(userId: string, dto: CreateChallengeInput) {
    const game = await this.games.getByKey(dto.gameKey);
    if (game.status !== 'ACTIVE') throw new ConflictException('Game is not available');
    if (game.minPlayers !== 2 || game.maxPlayers !== 2) {
      throw new BadRequestException('Challenges are for 1v1 games');
    }

    let inviteeId: string | null = null;
    const requested = dto.inviteeUsername?.trim() ?? '';
    if (requested) {
      const invitee = await this.prisma.user.findFirst({
        where: { username: requested.toLowerCase(), deletedAt: null },
        select: { id: true, username: true },
      });
      if (!invitee) throw new NotFoundException('User not found');
      if (invitee.id === userId) throw new BadRequestException('You cannot challenge yourself');
      if (await this.isBlocked(userId, invitee.id)) {
        throw new ForbiddenException('Cannot send to this player');
      }
      inviteeId = invitee.id;
    }

    // Abuse controls: cap creations per hour and how many may sit pending.
    const oneHourAgo = new Date(Date.now() - 60 * 60 * 1000);
    const recent = await this.prisma.challenge.count({
      where: { challengerId: userId, createdAt: { gte: oneHourAgo } },
    });
    if (recent >= this.social.challengeCreatePerHour) {
      throw new HttpException('Too many challenges created. Try again later.', 429);
    }
    const pending = await this.prisma.challenge.count({
      where: { challengerId: userId, status: 'PENDING' },
    });
    if (pending >= this.social.challengePendingLimit) {
      throw new HttpException('Too many pending challenges. Wait for a reply.', 429);
    }

    const row = await this.createWithUniqueCode({
      gameKey: game.key,
      challengerId: userId,
      inviteeId,
      expiresAt: new Date(Date.now() + this.social.challengeTtlSeconds * 1000),
    });

    if (inviteeId) {
      const me = await this.prisma.user.findUnique({
        where: { id: userId },
        select: { username: true },
      });
      await this.notifications.notify({
        userId: inviteeId,
        type: 'challenge',
        title: 'New challenge',
        body: `${me?.username ?? 'Someone'} challenged you to ${game.name}`,
        data: { code: row.code, gameKey: game.key },
      });
    }
    return this.serializeOne(row);
  }

  async inbox(userId: string) {
    await this.expireStale();
    const [incoming, outgoing] = await Promise.all([
      this.prisma.challenge.findMany({
        where: { inviteeId: userId, status: 'PENDING' },
        include: CHALLENGE_INCLUDE,
        orderBy: { createdAt: 'desc' },
        take: 20,
      }),
      this.prisma.challenge.findMany({
        where: { challengerId: userId, status: 'PENDING' },
        include: CHALLENGE_INCLUDE,
        orderBy: { createdAt: 'desc' },
        take: 20,
      }),
    ]);
    const [inc, out] = await Promise.all([
      this.serializeMany(incoming),
      this.serializeMany(outgoing),
    ]);
    return { incoming: inc, outgoing: out };
  }

  async get(userId: string, code: string) {
    await this.expireStale();
    const row = await this.requireByCode(code);
    if (row.inviteeId && row.inviteeId !== userId && row.challengerId !== userId) {
      throw new NotFoundException('Challenge not found');
    }
    if (await this.isBlocked(userId, row.challengerId)) {
      throw new NotFoundException('Challenge not found');
    }
    return this.serializeOne(row);
  }

  async accept(userId: string, code: string) {
    await this.expireStale();
    const row = await this.requireByCode(code);
    if (row.challengerId === userId) {
      throw new BadRequestException('You cannot accept your own challenge');
    }
    if (row.inviteeId && row.inviteeId !== userId) {
      throw new NotFoundException('Challenge not found');
    }
    if (row.status !== 'PENDING') throw this.statusConflict(row.status);
    if (await this.isBlocked(userId, row.challengerId)) {
      throw new NotFoundException('Challenge not found');
    }

    // Optimistic flip: only one accept can move PENDING → ACCEPTED.
    const flipped = await this.prisma.challenge.updateMany({
      where: { id: row.id, status: 'PENDING' },
      data: { status: 'ACCEPTED', respondedAt: new Date() },
    });
    if (flipped.count === 0) throw new ConflictException('Challenge is no longer available');

    try {
      const match = await this.matches.create(row.challengerId, {
        gameKey: row.gameKey,
        mode: 'PRIVATE',
      });
      const joined = await this.matches.join(userId, match.id);
      const updated = await this.prisma.challenge.update({
        where: { id: row.id },
        data: { matchId: match.id },
        include: CHALLENGE_INCLUDE,
      });
      const me = await this.prisma.user.findUnique({
        where: { id: userId },
        select: { username: true },
      });
      await this.notifications.notify({
        userId: row.challengerId,
        type: 'challenge_accepted',
        title: 'Challenge accepted',
        body: `${me?.username ?? 'Someone'} accepted your challenge`,
        data: { code: row.code, matchId: match.id, gameKey: row.gameKey },
      });
      const seat = joined.players.find((p) => p.userId === userId)?.seat ?? null;
      return { ...(await this.serializeOne(updated)), seat };
    } catch (err) {
      await this.prisma.challenge
        .update({ where: { id: row.id }, data: { status: 'PENDING', respondedAt: null } })
        .catch(() => undefined);
      throw err;
    }
  }

  async decline(userId: string, code: string) {
    await this.expireStale();
    const row = await this.requireByCode(code);
    if (row.challengerId === userId) {
      throw new BadRequestException('Cancel your own challenge instead');
    }
    if (row.inviteeId && row.inviteeId !== userId) {
      throw new NotFoundException('Challenge not found');
    }
    if (row.status !== 'PENDING') throw this.statusConflict(row.status);
    if (await this.isBlocked(userId, row.challengerId)) {
      throw new NotFoundException('Challenge not found');
    }
    const res = await this.prisma.challenge.updateMany({
      where: { id: row.id, status: 'PENDING' },
      data: { status: 'DECLINED', respondedAt: new Date() },
    });
    if (res.count === 0) throw new ConflictException('Challenge is no longer available');
    return this.serializeOne({ ...row, status: 'DECLINED' as ChallengeStatus });
  }

  async cancel(userId: string, code: string) {
    await this.expireStale();
    const row = await this.requireByCode(code);
    if (row.challengerId !== userId) {
      throw new ForbiddenException('Only the challenger can cancel');
    }
    if (row.status !== 'PENDING') throw this.statusConflict(row.status);
    const res = await this.prisma.challenge.updateMany({
      where: { id: row.id, status: 'PENDING' },
      data: { status: 'CANCELLED', respondedAt: new Date() },
    });
    if (res.count === 0) throw new ConflictException('Challenge is no longer available');
    return this.serializeOne({ ...row, status: 'CANCELLED' as ChallengeStatus });
  }

  // -------------------------------------------------------------------------
  // Serialization
  // -------------------------------------------------------------------------

  serialize(ch: ChallengeWithUsers, gameName?: string) {
    return {
      id: ch.id,
      code: ch.code,
      gameKey: ch.gameKey,
      gameName: gameName ?? ch.gameKey,
      status: ch.status,
      createdAt: ch.createdAt.toISOString(),
      expiresAt: ch.expiresAt.toISOString(),
      respondedAt: ch.respondedAt?.toISOString() ?? null,
      matchId: ch.matchId,
      challenger: ch.challenger,
      invitee: ch.invitee,
    };
  }

  private async serializeOne(row: ChallengeWithUsers) {
    return (await this.serializeMany([row]))[0];
  }

  private async serializeMany(rows: ChallengeWithUsers[]) {
    const keys = [...new Set(rows.map((r) => r.gameKey))];
    const games = keys.length
      ? await this.prisma.game.findMany({
          where: { key: { in: keys } },
          select: { key: true, name: true },
        })
      : [];
    const nameByKey = new Map(games.map((g) => [g.key, g.name]));
    return rows.map((r) => this.serialize(r, nameByKey.get(r.gameKey)));
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /** Lazily flips overdue PENDING challenges to EXPIRED. */
  private async expireStale() {
    await this.prisma.challenge.updateMany({
      where: { status: 'PENDING', expiresAt: { lt: new Date() } },
      data: { status: 'EXPIRED' },
    });
  }

  private async requireByCode(code: string): Promise<ChallengeWithUsers> {
    const normalized = code.toUpperCase();
    if (!CODE_PATTERN.test(normalized)) throw new NotFoundException('Challenge not found');
    const row = await this.prisma.challenge.findUnique({
      where: { code: normalized },
      include: CHALLENGE_INCLUDE,
    });
    if (!row) throw new NotFoundException('Challenge not found');
    return row;
  }

  /** True when either side has blocked the other. */
  private async isBlocked(a: string, b: string): Promise<boolean> {
    const row = await this.prisma.friendship.findFirst({
      where: {
        status: 'BLOCKED',
        OR: [
          { requesterId: a, addresseeId: b },
          { requesterId: b, addresseeId: a },
        ],
      },
      select: { id: true },
    });
    return row !== null;
  }

  private async createWithUniqueCode(data: {
    gameKey: string;
    challengerId: string;
    inviteeId: string | null;
    expiresAt: Date;
  }): Promise<ChallengeWithUsers> {
    let lastError: unknown;
    for (let attempt = 0; attempt < 5; attempt++) {
      try {
        return await this.prisma.challenge.create({
          data: { ...data, code: this.generateCode() },
          include: CHALLENGE_INCLUDE,
        });
      } catch (err) {
        lastError = err;
        const isCollision =
          err instanceof Prisma.PrismaClientKnownRequestError && err.code === 'P2002';
        if (!isCollision) throw err;
      }
    }
    throw lastError instanceof Error
      ? lastError
      : new ConflictException('Could not create challenge');
  }

  private generateCode(): string {
    let out = '';
    for (let i = 0; i < CODE_LENGTH; i++) {
      out += CODE_ALPHABET[randomInt(0, CODE_ALPHABET.length)];
    }
    return out;
  }

  private statusConflict(status: ChallengeStatus): ConflictException {
    switch (status) {
      case 'ACCEPTED':
        return new ConflictException('Challenge was already accepted');
      case 'DECLINED':
        return new ConflictException('Challenge was declined');
      case 'CANCELLED':
        return new ConflictException('Challenge was cancelled');
      case 'EXPIRED':
        return new ConflictException('Challenge has expired');
      default:
        return new ConflictException('Challenge is not available');
    }
  }
}
