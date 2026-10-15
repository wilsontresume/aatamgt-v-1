import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { AnalyticsEventType, Prisma } from '@prisma/client';
import { PrismaService } from '../prisma/prisma.service';

/**
 * Client-reported event types. Everything else in AnalyticsEventType is
 * server-authoritative and can only be written by in-process hooks —
 * a client that submits one is rejected, so purchase/ad/match metrics
 * cannot be spoofed from the network.
 */
export const CLIENT_EVENT_TYPES = [
  'install',
  'first_launch',
  'session_start',
  'session_end',
  'game_selected',
  'ai_match_completed',
  'share',
  'guest_conversion',
] as const satisfies readonly AnalyticsEventType[];

const CLIENT_TYPE_SET = new Set<string>(CLIENT_EVENT_TYPES);

/** Hard cap on a single event's JSON payload (anti-abuse). */
const MAX_DATA_BYTES = 2048;

/** Summary window is capped so one query can never scan years. */
const MAX_SUMMARY_DAYS = 366;

export interface AnalyticsRecordInput {
  type: AnalyticsEventType;
  userId?: string | null;
  installId?: string | null;
  sessionId?: string | null;
  gameKey?: string | null;
  platform?: string | null;
  version?: string | null;
  data?: Record<string, unknown> | null;
  dedupeKey?: string | null;
}

export interface ClientEventInput {
  type: string;
  sessionId?: string;
  gameKey?: string;
  data?: Record<string, unknown>;
  dedupeKey?: string;
}

export interface ClientIngestInput {
  installId?: string;
  platform?: string;
  version?: string;
  events: ClientEventInput[];
}

function utcDay(date: Date): Date {
  return new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
}

function parseDay(value: string, field: string): Date {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new BadRequestException(`${field} must be YYYY-MM-DD`);
  }
  const parsed = new Date(`${value}T00:00:00.000Z`);
  if (Number.isNaN(parsed.getTime())) throw new BadRequestException(`${field} is not a date`);
  return parsed;
}

@Injectable()
export class AnalyticsService {
  private readonly logger = new Logger(AnalyticsService.name);

  constructor(private readonly prisma: PrismaService) {}

  /**
   * Fire-and-forget write used by in-process hooks. Analytics must NEVER
   * break the business flow it observes: every failure is swallowed and
   * logged. Duplicate dedupeKeys are treated as success (idempotent).
   */
  async record(input: AnalyticsRecordInput): Promise<void> {
    try {
      const now = new Date();
      await this.prisma.analyticsEvent.create({
        data: {
          type: input.type,
          userId: input.userId ?? null,
          installId: input.installId ?? null,
          sessionId: input.sessionId ?? null,
          gameKey: input.gameKey ?? null,
          platform: input.platform ?? null,
          version: input.version ?? null,
          data: (input.data ?? undefined) as Prisma.InputJsonValue | undefined,
          dedupeKey: input.dedupeKey ?? null,
        },
      });
      const touches: Array<Promise<unknown>> = [];
      if (input.userId) touches.push(this.touchDay('USER', input.userId, now));
      if (input.installId) touches.push(this.touchDay('INSTALL', input.installId, now));
      await Promise.all(touches);
    } catch (error) {
      if (this.isDuplicate(error)) return;
      this.logger.warn(`record(${input.type}) failed: ${String(error)}`);
    }
  }

  /** Authenticated batch from a signed-in client. */
  async ingestClientEvents(
    userId: string,
    body: ClientIngestInput,
  ): Promise<{ accepted: number }> {
    await this.writeBatch(userId, body);
    return { accepted: body.events.length };
  }

  /** Pre-login batch identified only by a client-minted random installId. */
  async ingestAnonymousEvents(body: ClientIngestInput & { installId: string }): Promise<{ accepted: number }> {
    await this.writeBatch(null, body);
    return { accepted: body.events.length };
  }

  private async writeBatch(userId: string | null, body: ClientIngestInput): Promise<void> {
    for (const event of body.events) {
      if (!CLIENT_TYPE_SET.has(event.type)) {
        throw new BadRequestException(`Event type '${event.type}' is not client-reportable`);
      }
      if (event.data && JSON.stringify(event.data).length > MAX_DATA_BYTES) {
        throw new BadRequestException('Event data is too large');
      }
      await this.record({
        type: event.type as AnalyticsEventType,
        userId,
        installId: body.installId ?? null,
        sessionId: event.sessionId ?? null,
        gameKey: event.gameKey ?? null,
        platform: body.platform ?? null,
        version: body.version ?? null,
        data: event.data ?? null,
        dedupeKey: event.dedupeKey ?? null,
      });
    }
  }

  /**
   * Admin metrics: totals, acquisition, DAU/MAU, D1..D30 retention,
   * game outcomes, social and monetization counts — all derived from
   * the event log and the AnalyticsActiveDay rollup.
   */
  async summary(fromValue: string, toValue: string): Promise<Record<string, unknown>> {
    const from = parseDay(fromValue, 'from');
    const to = parseDay(toValue, 'to');
    if (to.getTime() < from.getTime()) throw new BadRequestException('to must not precede from');
    const spanDays = (to.getTime() - from.getTime()) / 86_400_000 + 1;
    if (spanDays > MAX_SUMMARY_DAYS) {
      throw new BadRequestException(`Range is capped at ${MAX_SUMMARY_DAYS} days`);
    }
    const toInclusive = new Date(to.getTime() + 86_399_999);
    const retentionHorizon = new Date(to.getTime() + 31 * 86_400_000);

    const [totals, activeUserDays, installDays, sessionEnds] = await Promise.all([
      this.prisma.analyticsEvent.groupBy({
        by: ['type'],
        where: { createdAt: { gte: from, lte: toInclusive } },
        _count: { _all: true },
      }),
      this.prisma.analyticsActiveDay.findMany({
        where: {
          subjectType: 'USER',
          day: { gte: from, lte: to },
        },
        select: { subjectId: true, day: true },
      }),
      this.prisma.analyticsActiveDay.findMany({
        where: {
          subjectType: 'INSTALL',
          day: { gte: from, lte: retentionHorizon },
        },
        select: { subjectId: true, day: true },
      }),
      this.prisma.analyticsEvent.findMany({
        where: { type: 'session_end', createdAt: { gte: from, lte: toInclusive } },
        select: { data: true },
      }),
    ]);

    const totalByType = new Map<string, number>();
    for (const row of totals) totalByType.set(row.type, row._count._all);
    const count = (type: string): number => totalByType.get(type) ?? 0;

    // DAU: distinct USER subjects per day; MAU: rolling 28-day window.
    const dauByDay = new Map<string, Set<string>>();
    for (const row of activeUserDays) {
      const key = row.day.toISOString().slice(0, 10);
      let bucket = dauByDay.get(key);
      if (!bucket) {
        bucket = new Set();
        dauByDay.set(key, bucket);
      }
      bucket.add(row.subjectId);
    }
    const dauSeries: Array<{ day: string; users: number }> = [];
    for (let cursor = from.getTime(); cursor <= to.getTime(); cursor += 86_400_000) {
      const key = new Date(cursor).toISOString().slice(0, 10);
      dauSeries.push({ day: key, users: dauByDay.get(key)?.size ?? 0 });
    }
    const mau28 = this.windowDistinct(activeUserDays, new Date(to.getTime() - 27 * 86_400_000), to);

    // Retention: per install cohort (first active day) share active on D+N.
    const firstActiveDay = new Map<string, number>();
    for (const row of installDays) {
      const time = row.day.getTime();
      const current = firstActiveDay.get(row.subjectId);
      if (current === undefined || time < current) firstActiveDay.set(row.subjectId, time);
    }
    const activeTimes = new Map<string, Set<number>>();
    for (const row of installDays) {
      let bucket = activeTimes.get(row.subjectId);
      if (!bucket) {
        bucket = new Set();
        activeTimes.set(row.subjectId, bucket);
      }
      bucket.add(row.day.getTime());
    }
    const cohortByOffset = (offsetDays: number) => {
      let cohort = 0;
      let retained = 0;
      for (const [subjectId, first] of firstActiveDay) {
        if (first < from.getTime() || first > to.getTime()) continue;
        cohort += 1;
        if (activeTimes.get(subjectId)?.has(first + offsetDays * 86_400_000)) retained += 1;
      }
      return {
        cohort,
        retained,
        rate: cohort === 0 ? 0 : Number((retained / cohort).toFixed(4)),
      };
    };

    let sessionSecondsTotal = 0;
    let sessionsWithDuration = 0;
    for (const row of sessionEnds) {
      const data = row.data as { durationSeconds?: unknown } | null;
      const duration = typeof data?.durationSeconds === 'number' ? data.durationSeconds : null;
      if (duration !== null && duration >= 0) {
        sessionSecondsTotal += duration;
        sessionsWithDuration += 1;
      }
    }
    const sessionStarts = count('session_start');
    const onlineMatches = count('match_completed');
    const aiMatches = count('ai_match_completed');

    const matchEvents = await this.prisma.analyticsEvent.findMany({
      where: { type: 'match_completed', createdAt: { gte: from, lte: toInclusive } },
      select: { gameKey: true, data: true },
    });
    interface GameBucket {
      wins: number;
      losses: number;
      draws: number;
      abandoned: number;
      byReason: Record<string, number>;
    }
    const perGame = new Map<string, GameBucket>();
    for (const row of matchEvents) {
      const key = row.gameKey ?? 'unknown';
      let bucket = perGame.get(key);
      if (!bucket) {
        bucket = { wins: 0, losses: 0, draws: 0, abandoned: 0, byReason: {} };
        perGame.set(key, bucket);
      }
      const data = row.data as { result?: unknown; reason?: unknown } | null;
      if (data?.result === 'WIN') bucket.wins += 1;
      else if (data?.result === 'LOSS') bucket.losses += 1;
      else if (data?.result === 'DRAW') bucket.draws += 1;
      const reason = typeof data?.reason === 'string' ? data.reason : 'UNKNOWN';
      bucket.byReason[reason] = (bucket.byReason[reason] ?? 0) + 1;
      if (reason !== 'RULES') bucket.abandoned += 1;
    }

    return {
      from: fromValue,
      to: toValue,
      acquisition: {
        install: count('install'),
        firstLaunch: count('first_launch'),
        registration: count('registration'),
        guestConversion: count('guest_conversion'),
      },
      engagement: {
        dauSeries,
        mau28,
        sessions: sessionStarts,
        avgSessionSeconds:
          sessionsWithDuration === 0
            ? 0
            : Number((sessionSecondsTotal / sessionsWithDuration).toFixed(1)),
        matchesPerSession:
          sessionStarts === 0
            ? 0
            : Number(((onlineMatches + aiMatches) / sessionStarts).toFixed(2)),
      },
      retention: {
        d1: cohortByOffset(1),
        d3: cohortByOffset(3),
        d7: cohortByOffset(7),
        d14: cohortByOffset(14),
        d30: cohortByOffset(30),
      },
      game: {
        onlineMatches,
        aiMatches,
        perGame: [...perGame.entries()].map(([gameKey, bucket]) => ({ gameKey, ...bucket })),
      },
      social: {
        friendRequests: count('friend_request'),
        challengesCreated: count('challenge_created'),
        challengesAccepted: count('challenge_accepted'),
        shares: count('share'),
      },
      monetization: {
        rewardedStarted: count('rewarded_ad_started'),
        rewardedCompleted: count('rewarded_ad_completed'),
        interstitials: count('interstitial_displayed'),
        royalPassPurchases: count('royal_pass_purchase'),
        coinPurchases: count('coin_purchase'),
        cosmeticPurchases: count('cosmetic_purchase'),
      },
      totals: Object.fromEntries([...totalByType.entries()].sort()),
    };
  }

  private windowDistinct(
    rows: Array<{ subjectId: string; day: Date }>,
    from: Date,
    to: Date,
  ): number {
    const subjects = new Set<string>();
    const fromTime = from.getTime();
    const toTime = to.getTime();
    for (const row of rows) {
      const time = row.day.getTime();
      if (time >= fromTime && time <= toTime) subjects.add(row.subjectId);
    }
    return subjects.size;
  }

  private async touchDay(
    subjectType: 'INSTALL' | 'USER',
    subjectId: string,
    now: Date,
  ): Promise<void> {
    const day = utcDay(now);
    await this.prisma.analyticsActiveDay.upsert({
      where: { subjectType_subjectId_day: { subjectType, subjectId, day } },
      create: { subjectType, subjectId, day },
      update: {},
    });
  }

  private isDuplicate(error: unknown): boolean {
    return (
      error instanceof Prisma.PrismaClientKnownRequestError &&
      error.code === 'P2002'
    );
  }
}
