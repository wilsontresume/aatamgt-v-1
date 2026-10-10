import { ConflictException, ForbiddenException, NotFoundException } from '@nestjs/common';
import { MatchesService } from '../../src/matches/matches.service';

const game = {
  id: 'g1',
  key: 'aadu-puli-aattam',
  status: 'ACTIVE',
  minPlayers: 2,
  maxPlayers: 2,
};

const player = (userId: string, seat: number) => ({
  id: `mp-${userId}`,
  userId,
  seat,
  result: 'PENDING',
  score: 0,
  team: null,
  color: null,
  user: { username: `user-${userId}` },
});

const matchRow = (overrides: Record<string, unknown> = {}) => ({
  id: 'm1',
  gameId: 'g1',
  gameKey: 'fixture-game',
  status: 'PENDING',
  mode: 'CASUAL',
  stateVersion: 0,
  serverState: null,
  stakeCoins: 0,
  createdByUserId: 'u1',
  startedAt: null,
  completedAt: null,
  createdAt: new Date(),
  updatedAt: new Date(),
  players: [player('u1', 0)],
  ...overrides,
});

function makeMatches(
  opts: {
    match?: unknown;
    matchFor?: unknown;
    moveCount?: number;
  } = {},
) {
  const match = (opts.match ?? matchRow()) as Record<string, unknown>;

  const prisma: any = {
    gameMatch: {
      create: jest.fn().mockResolvedValue(match),
      findUnique: jest.fn().mockResolvedValue(opts.matchFor !== undefined ? opts.matchFor : match),
      update: jest.fn().mockResolvedValue(match),
      findMany: jest.fn().mockResolvedValue([]),
    },
    matchPlayer: {
      create: jest.fn().mockResolvedValue({}),
      delete: jest.fn().mockResolvedValue({}),
      update: jest.fn().mockResolvedValue({}),
    },
    matchMove: {
      count: jest.fn().mockResolvedValue(opts.moveCount ?? 0),
      create: jest.fn().mockResolvedValue({
        id: 'mv1',
        seq: 1,
        serverAt: new Date(),
        payload: {},
      }),
      findMany: jest.fn().mockResolvedValue([]),
    },
    profile: {
      findMany: jest.fn().mockResolvedValue([]),
      updateMany: jest.fn().mockResolvedValue({}),
      update: jest.fn().mockResolvedValue({}),
    },
    $transaction: jest.fn(async (fn: (tx: unknown) => Promise<unknown>) => fn(prisma)),
  };
  const games = { getByKey: jest.fn().mockResolvedValue(game) };
  const events = { publish: jest.fn() };
  const clock = {
    armTurn: jest.fn(),
    disarmTurn: jest.fn(),
    disarmMatch: jest.fn(),
    armDisconnect: jest.fn(),
    disarmDisconnect: jest.fn(),
    hasDisconnect: jest.fn().mockReturnValue(false),
  };
  const config = {
    get: jest.fn().mockReturnValue({
      match: { turnTimeoutMs: 60_000, disconnectGraceMs: 30_000 },
    }),
  };
  const rankings = { applyMatchResult: jest.fn().mockResolvedValue([]) };
  prisma.$queryRaw = jest.fn().mockResolvedValue([]);
  const service = new MatchesService(
    prisma as never,
    games as never,
    events as never,
    clock as never,
    rankings as never,
    config as never,
  );
  return { service, prisma, games, events, clock, rankings, config };
}

describe('MatchesService', () => {
  it('refuses to create a match with a stake while gameplay is unimplemented', async () => {
    const { service } = makeMatches({});
    await expect(
      service.create('u1', { gameKey: 'aadu-puli-aattam', stakeCoins: 100 }),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('creates a pending match with the creator in seat 0', async () => {
    const { service, prisma } = makeMatches({});
    const match = await service.create('u1', { gameKey: 'aadu-puli-aattam' });
    expect(match.status).toBe('PENDING');
    expect(prisma.gameMatch.create).toHaveBeenCalledWith(
      expect.objectContaining({
        data: expect.objectContaining({
          players: { create: { userId: 'u1', seat: 0 } },
        }),
      }),
    );
  });

  it('activates a match when the second player joins', async () => {
    const pending = matchRow({ players: [player('u1', 0)] });
    const active = matchRow({
      status: 'ACTIVE',
      startedAt: new Date(),
      stateVersion: 1,
      players: [player('u1', 0), player('u2', 1)],
    });
    const { service, prisma } = makeMatches({ match: pending });
    (prisma.gameMatch.update as jest.Mock).mockResolvedValue(active);

    const match = await service.join('u2', 'm1');
    expect(match.status).toBe('ACTIVE');
    expect(prisma.matchPlayer.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ userId: 'u2', seat: 1 }) }),
    );
  });

  it('rejects moves from non-participants', async () => {
    const active = matchRow({ status: 'ACTIVE' });
    const { service } = makeMatches({ match: active });
    await expect(
      service.submitMove('intruder', 'm1', { payload: { to: 'a3' } }),
    ).rejects.toBeInstanceOf(ForbiddenException);
  });

  it('rejects moves while the match is not active', async () => {
    const { service } = makeMatches({});
    await expect(service.submitMove('u1', 'm1', { payload: { to: 'a3' } })).rejects.toBeInstanceOf(
      ConflictException,
    );
  });

  it('rejects an out-of-order client sequence', async () => {
    const active = matchRow({ status: 'ACTIVE' });
    const { service } = makeMatches({ match: active, moveCount: 3 });
    await expect(
      service.submitMove('u1', 'm1', { payload: { to: 'a3' }, clientSeq: 1 }),
    ).rejects.toBeInstanceOf(ConflictException);
  });

  it('assigns the sequence server-side and never computes a result', async () => {
    const active = matchRow({ status: 'ACTIVE' });
    const { service, prisma, events } = makeMatches({ match: active, moveCount: 3 });

    const result = await service.submitMove('u1', 'm1', { payload: { to: 'a3' } });

    expect(result.move.seq).toBe(4);
    expect(prisma.matchMove.create).toHaveBeenCalledWith(
      expect.objectContaining({ data: expect.objectContaining({ seq: 4, userId: 'u1' }) }),
    );
    expect(events.publish).toHaveBeenCalledWith(expect.objectContaining({ kind: 'move' }));
    const updateData = prisma.gameMatch.update.mock.calls[0][0].data as Record<string, unknown>;
    expect(updateData.status).toBeUndefined();
    expect(JSON.stringify(updateData)).not.toMatch(/WIN|LOSS|DRAW|winner/i);
  });

  it('treats an active leave as a server-decided resignation (loss-dodge regression)', async () => {
    const players = [player('u1', 0), player('u2', 1)];
    const active = matchRow({ status: 'ACTIVE', players });
    const completed = matchRow({ status: 'COMPLETED', completedAt: new Date(), players });
    const { service, prisma, events, clock, rankings } = makeMatches({ match: active });
    prisma.gameMatch.findUnique
      .mockResolvedValueOnce(active) // leave() snapshot
      .mockResolvedValueOnce(active) // locked read inside the transaction
      .mockResolvedValue(completed); // final refetch
    prisma.gameMatch.update.mockResolvedValue(completed);

    const result = await service.leave('u2', 'm1');

    expect(result.status).toBe('COMPLETED');
    // u2 (seat 1) left, so seat 0 wins and both results are decided —
    // before the fix the match ended ABANDONED with no result at all.
    const results = prisma.matchPlayer.update.mock.calls.map(
      (call: [{ data: { result: string } }]) => call[0].data.result,
    );
    expect(results).toEqual(['WIN', 'LOSS']);
    expect(prisma.profile.updateMany).toHaveBeenCalledTimes(2);
    expect(rankings.applyMatchResult).toHaveBeenCalledTimes(1);
    expect(clock.disarmMatch).toHaveBeenCalledWith('m1');
    expect(events.publish).toHaveBeenCalledWith(
      expect.objectContaining({
        kind: 'status',
        data: expect.objectContaining({ status: 'COMPLETED' }),
      }),
    );
  });

  it('cancels a solo pending match created by the owner', async () => {
    const cancelled = matchRow({ status: 'CANCELLED' });
    const { service, prisma } = makeMatches({});
    (prisma.gameMatch.update as jest.Mock).mockResolvedValue(cancelled);

    const result = await service.leave('u1', 'm1');
    expect(result.status).toBe('CANCELLED');
  });

  it('reports unknown matches as not found', async () => {
    const { service } = makeMatches({ matchFor: null });
    await expect(service.getMatch('missing')).rejects.toBeInstanceOf(NotFoundException);
  });
});
