import { BadRequestException } from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { AnalyticsService } from '../../src/analytics/analytics.service';

type MockFn = jest.Mock & { mockResolvedValue?: (value: unknown) => unknown };

function makePrisma(overrides: Record<string, unknown> = {}) {
  const base = {
    analyticsEvent: {
      create: jest.fn().mockResolvedValue({}),
      count: jest.fn().mockResolvedValue(0),
      groupBy: jest.fn().mockResolvedValue([]),
      findMany: jest.fn().mockResolvedValue([]),
    },
    analyticsActiveDay: {
      upsert: jest.fn().mockResolvedValue({}),
      findMany: jest.fn().mockResolvedValue([]),
    },
  };
  return { ...base, ...overrides } as never;
}

function makeService(prisma = makePrisma()): AnalyticsService {
  return new AnalyticsService(prisma);
}

describe('AnalyticsService.record (fire-and-forget)', () => {
  it('writes the event and touches both active-day subjects', async () => {
    const prisma = makePrisma();
    const service = makeService(prisma);
    await service.record({
      type: 'session_start',
      userId: 'u1',
      installId: 'i1',
      sessionId: 's1',
    });
    const writes = (prisma as never as { analyticsEvent: { create: MockFn } }).analyticsEvent
      .create as unknown as jest.Mock;
    expect(writes).toHaveBeenCalledTimes(1);
    expect(writes.mock.calls[0][0].data).toMatchObject({
      type: 'session_start',
      userId: 'u1',
      installId: 'i1',
      sessionId: 's1',
    });
    const days = (prisma as never as { analyticsActiveDay: { upsert: MockFn } })
      .analyticsActiveDay.upsert as unknown as jest.Mock;
    expect(days).toHaveBeenCalledTimes(2); // USER + INSTALL
  });

  it('never throws when the write fails (analytics must not break flows)', async () => {
    const prisma = makePrisma();
    (prisma as never as { analyticsEvent: { create: jest.Mock } }).analyticsEvent.create =
      jest.fn().mockRejectedValue(new Error('db down')) as never;
    const service = makeService(prisma);
    await expect(service.record({ type: 'registration', userId: 'u1' })).resolves.toBeUndefined();
  });

  it('treats a duplicate dedupeKey as success', async () => {
    const prisma = makePrisma();
    const duplicate = new Prisma.PrismaClientKnownRequestError('Unique constraint failed', {
      code: 'P2002',
      clientVersion: 'test',
    });
    (prisma as never as { analyticsEvent: { create: jest.Mock } }).analyticsEvent.create =
      jest.fn().mockRejectedValue(duplicate) as never;
    const service = makeService(prisma);
    await expect(
      service.record({ type: 'install', dedupeKey: 'install:i1' }),
    ).resolves.toBeUndefined();
  });
});

describe('AnalyticsService client ingest (allow-list)', () => {
  it('accepts allow-listed client events and stamps the userId', async () => {
    const prisma = makePrisma();
    const service = makeService(prisma);
    const result = await service.ingestClientEvents('u1', {
      events: [{ type: 'session_start', sessionId: 's1' }],
    });
    expect(result).toEqual({ accepted: 1 });
    const writes = (prisma as never as { analyticsEvent: { create: MockFn } }).analyticsEvent
      .create as unknown as jest.Mock;
    expect(writes.mock.calls[0][0].data).toMatchObject({ type: 'session_start', userId: 'u1' });
  });

  it('rejects server-authoritative types submitted by a client', async () => {
    const service = makeService();
    await expect(
      service.ingestClientEvents('u1', {
        events: [{ type: 'coin_purchase' as never }],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      service.ingestClientEvents('u1', {
        events: [{ type: 'match_completed' as never }],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
    await expect(
      service.ingestClientEvents('u1', {
        events: [{ type: 'rewarded_ad_completed' as never }],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('rejects oversized event data', async () => {
    const service = makeService();
    await expect(
      service.ingestClientEvents('u1', {
        events: [{ type: 'share', data: { blob: 'x'.repeat(4096) } }],
      }),
    ).rejects.toBeInstanceOf(BadRequestException);
  });

  it('anonymous ingest keys events by installId only (never a userId)', async () => {
    const prisma = makePrisma();
    const service = makeService(prisma);
    await service.ingestAnonymousEvents({
      installId: 'i-abc',
      events: [{ type: 'install' }, { type: 'first_launch' }],
    });
    const writes = (prisma as never as { analyticsEvent: { create: MockFn } }).analyticsEvent
      .create as unknown as jest.Mock;
    expect(writes).toHaveBeenCalledTimes(2);
    expect(writes.mock.calls[0][0].data).toMatchObject({ type: 'install', userId: null });
    expect(writes.mock.calls[1][0].data).toMatchObject({ type: 'first_launch', userId: null });
  });
});

describe('AnalyticsService.summary', () => {
  it('rejects an inverted or malformed range', async () => {
    const service = makeService();
    await expect(service.summary('2026-01-02', '2026-01-01')).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.summary('nope', '2026-01-01')).rejects.toBeInstanceOf(
      BadRequestException,
    );
    await expect(service.summary('2020-01-01', '2026-01-01')).rejects.toBeInstanceOf(
      BadRequestException,
    );
  });

  it('returns the acquisition/engagement/retention/game/social/monetization sections', async () => {
    const prisma = makePrisma();
    (
      prisma as never as {
        analyticsEvent: { groupBy: jest.Mock; findMany: jest.Mock };
      }
    ).analyticsEvent.groupBy = jest.fn().mockResolvedValue([
      { type: 'install', _count: { _all: 3 } },
      { type: 'match_completed', _count: { _all: 2 } },
      { type: 'coin_purchase', _count: { _all: 1 } },
    ]) as never;
    (
      prisma as never as { analyticsActiveDay: { findMany: jest.Mock } }
    ).analyticsActiveDay.findMany = jest
      .fn()
      .mockResolvedValueOnce([
        { subjectId: 'u1', day: new Date('2026-01-01T00:00:00.000Z') },
        { subjectId: 'u2', day: new Date('2026-01-01T00:00:00.000Z') },
      ])
      .mockResolvedValueOnce([
        { subjectId: 'i1', day: new Date('2026-01-01T00:00:00.000Z') },
        { subjectId: 'i1', day: new Date('2026-01-02T00:00:00.000Z') },
      ]) as never;
    (
      prisma as never as { analyticsEvent: { findMany: jest.Mock } }
    ).analyticsEvent.findMany = jest
      .fn()
      .mockResolvedValueOnce([{ data: { durationSeconds: 120 } }])
      .mockResolvedValueOnce([
        { gameKey: 'aadu-puli-aattam', data: { result: 'WIN', reason: 'RULES' } },
        { gameKey: 'aadu-puli-aattam', data: { result: 'LOSS', reason: 'DISCONNECT' } },
      ]) as never;

    const service = makeService(prisma);
    const summary = await service.summary('2026-01-01', '2026-01-02');

    expect(summary.acquisition).toMatchObject({ install: 3 });
    expect(summary.monetization).toMatchObject({ coinPurchases: 1 });
    const engagement = summary.engagement as { dauSeries: unknown[]; mau28: number };
    expect(engagement.dauSeries).toHaveLength(2);
    expect(engagement.mau28).toBe(2);
    const retention = summary.retention as { d1: { cohort: number; retained: number } };
    expect(retention.d1.cohort).toBe(1);
    expect(retention.d1.retained).toBe(1);
    const game = summary.game as { perGame: Array<{ gameKey: string; wins: number; abandoned: number }> };
    expect(game.perGame[0]).toMatchObject({
      gameKey: 'aadu-puli-aattam',
      wins: 1,
      abandoned: 1,
    });
  });
});
