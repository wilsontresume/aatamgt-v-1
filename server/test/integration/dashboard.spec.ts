import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import {
  apiPrefix,
  closePrisma,
  prisma,
  registerUser,
  TestUser,
} from '../helpers/fixtures';

const DAY_MS = 86_400_000;
const NOW = Date.now();
const dayOf = (offsetDays: number): string =>
  new Date(NOW - offsetDays * DAY_MS).toISOString().slice(0, 10);
const atNoon = (day: string): Date => new Date(`${day}T12:00:00.000Z`);
const dayStart = (day: string): Date => new Date(`${day}T00:00:00.000Z`);
const nextDayStart = (day: string): Date => new Date(dayStart(day).getTime() + DAY_MS);

// Fixed backdated window so rows created "now" by other fixtures can never
// leak into the assertions below.
const DAY_RECENT = dayOf(5);
const DAY_OLD = dayOf(20);
const DAY_OUTSIDE = dayOf(60);
const FROM = DAY_OLD;
const TO = DAY_RECENT;
const EXPECTED_SERIES_DAYS =
  Math.round((Date.parse(`${DAY_RECENT}T00:00:00Z`) - Date.parse(`${DAY_OLD}T00:00:00Z`)) / DAY_MS) + 1;

let app: INestApplication;
let prefix: string;
let admin: TestUser;
let moderator: TestUser;
let player: TestUser;
let gameA: string;
let gameB: string;
let circulationBefore: number;

async function makeMatch(
  gameKey: string,
  status: 'PENDING' | 'ACTIVE' | 'COMPLETED' | 'ABANDONED',
  seats: Array<{ userId?: string; isAi?: boolean }>,
  createdAt: Date,
): Promise<string> {
  const game = await prisma().game.findUniqueOrThrow({ where: { key: gameKey } });
  const match = await prisma().gameMatch.create({
    data: {
      gameId: game.id,
      gameKey,
      status,
      mode: 'CASUAL',
      stakeCoins: 50,
      tierId: 'bronze',
      createdByUserId: seats.find((seat) => seat.userId)?.userId ?? null,
      createdAt,
      players: {
        create: seats.map((seat, index) => ({
          seat: index + 1,
          userId: seat.userId ?? null,
          isAi: seat.isAi ?? false,
          aiName: seat.isAi ? `Bot${index}` : null,
        })),
      },
    },
  });
  return match.id;
}

beforeAll(async () => {
  app = await createTestApp();
  prefix = apiPrefix(app);
  admin = await registerUser(app, { role: 'ADMIN' });
  moderator = await registerUser(app, { role: 'MODERATOR' });
  player = await registerUser(app);

  gameA = `dash-${uniqueSuffix()}`;
  gameB = `dash-${uniqueSuffix()}`;
  await prisma().game.create({
    data: { key: gameA, name: 'Dashboard Game A', slug: gameA, minPlayers: 2, maxPlayers: 2 },
  });
  await prisma().game.create({
    data: { key: gameB, name: 'Dashboard Game B', slug: gameB, minPlayers: 2, maxPlayers: 2 },
  });

  // Registrations inside / outside the window.
  await prisma().user.create({
    data: {
      username: `dash_old_${uniqueSuffix()}`.slice(0, 30),
      passwordHash: 'not-a-real-hash',
      role: 'USER',
      createdAt: atNoon(DAY_OLD),
    },
  });
  await prisma().user.create({
    data: {
      username: `dash_new_${uniqueSuffix()}`.slice(0, 30),
      passwordHash: 'not-a-real-hash',
      role: 'USER',
      isGuest: true,
      createdAt: atNoon(DAY_RECENT),
    },
  });
  await prisma().user.create({
    data: {
      username: `dash_out_${uniqueSuffix()}`.slice(0, 30),
      passwordHash: 'not-a-real-hash',
      role: 'USER',
      createdAt: atNoon(DAY_OUTSIDE),
    },
  });

  // Matches inside the window: AI vs human, human vs human, AI-heavy, plus
  // one ACTIVE match backdated far outside the window (activeNow ignores range).
  await makeMatch(gameA, 'COMPLETED', [{ userId: admin.id }, { isAi: true }], atNoon(DAY_RECENT));
  await makeMatch(gameA, 'ABANDONED', [{ userId: admin.id }, { userId: player.id }], atNoon(DAY_OLD));
  await makeMatch(gameB, 'COMPLETED', [{ isAi: true }, { isAi: true }], atNoon(DAY_RECENT));
  await makeMatch(gameA, 'ACTIVE', [{ userId: admin.id }, { userId: player.id }], atNoon(DAY_OUTSIDE));

  // Ledger rows inside / outside the window (sign split + grants trend).
  const wallet = await prisma().wallet.findUniqueOrThrow({ where: { userId_currency: { userId: player.id, currency: 'COIN' } } });
  const mkTx = (
    type: 'DAILY_LOGIN' | 'REWARDED_AD' | 'MATCH_REWARD' | 'ADMIN_ADJUSTMENT',
    amount: number,
    day: string,
  ) =>
    prisma().walletTransaction.create({
      data: {
        walletId: wallet.id,
        amount,
        balanceAfter: Math.max(wallet.balance, 0),
        type,
        refType: 'test',
        refId: uniqueSuffix(),
        createdAt: atNoon(day),
      },
    });
  await mkTx('DAILY_LOGIN', 700, DAY_RECENT);
  await mkTx('REWARDED_AD', 300, DAY_OLD);
  await mkTx('MATCH_REWARD', -50, DAY_RECENT);
  await mkTx('ADMIN_ADJUSTMENT', 9_999, DAY_OUTSIDE);

  // One WAITING matchmaking ticket for queue depth.
  await prisma().matchmakingTicket.create({
    data: { userId: player.id, gameKey: gameA, tierId: 'bronze', status: 'WAITING' },
  });

  circulationBefore = 0;
  const agg = await prisma().wallet.aggregate({
    where: { currency: 'COIN' },
    _sum: { balance: true },
  });
  circulationBefore = agg._sum.balance ?? 0;
}, 60_000);

afterAll(async () => {
  await app?.close();
  await closePrisma();
});

function get(path: string, token?: string) {
  const req = request(app.getHttpServer()).get(`${prefix}${path}`);
  return token ? req.set('Authorization', `Bearer ${token}`) : req;
}

describe('GET /admin/dashboard — authorization', () => {
  it('rejects anonymous callers', async () => {
    const res = await get('/admin/dashboard');
    expect(res.status).toBe(401);
  });

  it('rejects ordinary players', async () => {
    const res = await get('/admin/dashboard', player.accessToken);
    expect(res.status).toBe(403);
  });

  it('allows moderators and admins', async () => {
    expect((await get('/admin/dashboard', moderator.accessToken)).status).toBe(200);
    expect((await get('/admin/dashboard', admin.accessToken)).status).toBe(200);
  });
});

describe('GET /admin/dashboard — filters and validation', () => {
  it('defaults to the last 14 days ending today', async () => {
    const res = await get('/admin/dashboard', admin.accessToken);
    expect(res.status).toBe(200);
    expect(res.body.range.to).toBe(dayOf(0));
    expect(res.body.range.from).toBe(dayOf(13));
    expect(res.body.users.registrations).toHaveLength(14);
    expect(res.body.range.gameKey).toBeNull();
  });

  it('rejects an inverted range', async () => {
    const res = await get(`/admin/dashboard?from=${TO}&to=${FROM}`, admin.accessToken);
    expect(res.status).toBe(400);
  });

  it('rejects malformed dates', async () => {
    const res = await get('/admin/dashboard?from=2026-13-99', admin.accessToken);
    expect(res.status).toBe(400);
  });

  it('rejects ranges longer than 366 days', async () => {
    const res = await get('/admin/dashboard?from=2024-01-01&to=2025-06-01', admin.accessToken);
    expect(res.status).toBe(400);
  });

  it('404s on an unknown gameKey', async () => {
    const res = await get('/admin/dashboard?gameKey=no-such-game', admin.accessToken);
    expect(res.status).toBe(404);
  });
});

describe('GET /admin/dashboard — metrics', () => {
  // The shared test database accumulates rows from every past suite run, so
  // window-wide expectations are computed from the database itself and then
  // cross-checked against the seeded fixtures. Game-key-scoped assertions are
  // absolute because the seeded keys are unique per run.
  it('counts users, guests and gap-fills the registration series', async () => {
    const res = await get(`/admin/dashboard?from=${FROM}&to=${TO}`, admin.accessToken);
    expect(res.status).toBe(200);

    const window = { gte: dayStart(FROM), lt: nextDayStart(TO) };
    const expectedRegistered = await prisma().user.count({
      where: { deletedAt: null, createdAt: window },
    });
    expect(res.body.users.registeredInRange).toBe(expectedRegistered);
    expect(expectedRegistered).toBeGreaterThanOrEqual(2); // both seeded users exist
    await expectSeededUsersRegistered(res.body.users.registrations);

    expect(res.body.users.registrations).toHaveLength(EXPECTED_SERIES_DAYS);
    for (const row of res.body.users.registrations) expect(row.count).toBeGreaterThanOrEqual(0);
    const byDate = Object.fromEntries(
      res.body.users.registrations.map((row: { date: string; count: number }) => [row.date, row.count]),
    );
    const seriesSum = res.body.users.registrations.reduce(
      (sum: number, row: { count: number }) => sum + row.count,
      0,
    );
    expect(seriesSum).toBe(expectedRegistered); // gap-filled, nothing lost or duplicated
    expect(byDate[DAY_OUTSIDE]).toBeUndefined();

    const expectedGuests = await prisma().user.count({ where: { isGuest: true, deletedAt: null } });
    expect(res.body.users.guests).toBe(expectedGuests);
    const expectedTotal = await prisma().user.count({ where: { deletedAt: null } });
    expect(res.body.users.total).toBe(expectedTotal);
  });

  it('breaks matches down by status and human-vs-AI', async () => {
    const res = await get(`/admin/dashboard?from=${FROM}&to=${TO}`, admin.accessToken);
    const m = res.body.matches;

    const window = { gte: dayStart(FROM), lt: nextDayStart(TO) };
    const expectedTotal = await prisma().gameMatch.count({ where: { createdAt: window } });
    const expectedAi = await prisma().gameMatch.count({
      where: { createdAt: window, players: { some: { isAi: true } } },
    });
    expect(m.totalInRange).toBe(expectedTotal);
    expect(expectedTotal).toBeGreaterThanOrEqual(3); // the three in-window seeds
    expect(m.humanVsAi).toBe(expectedAi);
    expect(expectedAi).toBeGreaterThanOrEqual(2);
    expect(m.humanVsHuman).toBe(expectedTotal - expectedAi);

    const statusRows = await prisma().gameMatch.groupBy({
      by: ['status'],
      where: { createdAt: window },
      _count: true,
    });
    const expectedByStatus: Record<string, number> = {
      PENDING: 0,
      ACTIVE: 0,
      PAUSED: 0,
      COMPLETED: 0,
      ABANDONED: 0,
      CANCELLED: 0,
    };
    for (const row of statusRows) expectedByStatus[row.status] = row._count;
    expect(m.byStatus).toEqual(expectedByStatus);
    expect(m.byStatus.COMPLETED).toBeGreaterThanOrEqual(2);

    // activeNow reflects current state regardless of the date range.
    const expectedActive = await prisma().gameMatch.count({
      where: { status: { in: ['ACTIVE', 'PAUSED'] } },
    });
    expect(m.activeNow).toBe(expectedActive);
    expect(m.activeNow).toBeGreaterThanOrEqual(1);
  });

  it('applies the game filter to matches', async () => {
    const res = await get(
      `/admin/dashboard?from=${FROM}&to=${TO}&gameKey=${gameA}`,
      admin.accessToken,
    );
    expect(res.status).toBe(200);
    // Absolute: the per-run unique game key scopes the window to seeded rows.
    expect(res.body.matches.totalInRange).toBe(2);
    expect(res.body.matches.humanVsAi).toBe(1);
    expect(res.body.matches.humanVsHuman).toBe(1);
    expect(res.body.matches.byGame).toHaveLength(1);
    expect(res.body.matches.byGame[0]).toMatchObject({ gameKey: gameA, name: 'Dashboard Game A', matches: 2 });

    const resB = await get(
      `/admin/dashboard?from=${FROM}&to=${TO}&gameKey=${gameB}`,
      admin.accessToken,
    );
    expect(resB.body.matches.totalInRange).toBe(1);
    expect(resB.body.matches.humanVsAi).toBe(1);
    expect(resB.body.matches.humanVsHuman).toBe(0);
  });

  it('reports real coin circulation and windowed ledger trends', async () => {
    const res = await get(`/admin/dashboard?from=${FROM}&to=${TO}`, admin.accessToken);
    const e = res.body.economy;

    expect(e.coinsCirculation).toBe(circulationBefore);
    expect(e.wallets).toBe(await prisma().wallet.count({ where: { currency: 'COIN' } }));

    const wallet = await prisma().wallet.findUniqueOrThrow({
      where: { userId_currency: { userId: player.id, currency: 'COIN' } },
    });
    const window = { gte: dayStart(FROM), lt: nextDayStart(TO) };
    const expectedIssued = await prisma().walletTransaction.aggregate({
      where: { createdAt: window, amount: { gt: 0 } },
      _sum: { amount: true },
    });
    const expectedSpent = await prisma().walletTransaction.aggregate({
      where: { createdAt: window, amount: { lt: 0 } },
      _sum: { amount: true },
    });
    const expectedTxCount = await prisma().walletTransaction.count({ where: { createdAt: window } });
    expect(e.issuedInRange).toBe(expectedIssued._sum.amount ?? 0);
    expect(e.spentInRange).toBe(Math.abs(expectedSpent._sum.amount ?? 0));
    expect(e.transactionsInRange).toBe(expectedTxCount);
    expect(expectedIssued._sum.amount ?? 0).toBeGreaterThanOrEqual(1000); // seeded 700 + 300

    const typeRows = await prisma().walletTransaction.groupBy({
      by: ['type'],
      where: { createdAt: window },
      _count: true,
      _sum: { amount: true },
    });
    const byType = Object.fromEntries(
      e.byType.map((row: { type: string; count: number; amount: number }) => [row.type, row]),
    );
    for (const row of typeRows) {
      expect(byType[row.type]).toBeDefined();
      expect(byType[row.type].count).toBe(row._count);
      expect(byType[row.type].amount).toBe(row._sum.amount ?? 0);
    }
    // The seeded +700 / +300 / -50 rows are present on the player wallet.
    expect(byType.DAILY_LOGIN).toBeDefined();
    expect(byType.REWARDED_AD).toBeDefined();
    expect(byType.MATCH_REWARD).toBeDefined();

    expect(e.grantsPerDay).toHaveLength(EXPECTED_SERIES_DAYS);
    const grantsByDate = Object.fromEntries(
      e.grantsPerDay.map((row: { date: string; count: number; amount: number }) => [row.date, row]),
    );
    expect(grantsByDate[DAY_OUTSIDE]).toBeUndefined();
    for (const row of e.grantsPerDay) {
      const expectedDay = await prisma().walletTransaction.aggregate({
        where: { createdAt: { gte: dayStart(row.date), lt: nextDayStart(row.date) }, amount: { gt: 0 } },
        _count: true,
        _sum: { amount: true },
      });
      expect(row.count).toBe(expectedDay._count);
      expect(row.amount).toBe(expectedDay._sum.amount ?? 0);
    }
    expect(grantsByDate[DAY_RECENT].amount).toBeGreaterThanOrEqual(700);
    expect(grantsByDate[DAY_OLD].amount).toBeGreaterThanOrEqual(300);
    // Seeded ledger rows live on the player wallet and are real.
    const playerTx = await prisma().walletTransaction.count({ where: { walletId: wallet.id } });
    expect(playerTx).toBeGreaterThanOrEqual(4); // registration bonus + three seeded rows
  });

  it('reports queue depth from live tickets', async () => {
    const res = await get(`/admin/dashboard?from=${FROM}&to=${TO}`, admin.accessToken);
    const expected = await prisma().matchmakingTicket.count({ where: { status: 'WAITING' } });
    expect(res.body.health.queueDepth).toBe(expected);
    expect(res.body.health.status).toBe('ok');
    expect(typeof res.body.health.uptimeSeconds).toBe('number');
    expect(res.body.health.dbLatencyMs).toBeGreaterThanOrEqual(0);
  });

  it('includes recent registrations for both staff roles', async () => {
    for (const token of [admin.accessToken, moderator.accessToken]) {
      const res = await get('/admin/dashboard', token);
      expect(res.body.recent.registrations.length).toBeGreaterThan(0);
      expect(res.body.recent.registrations[0]).toHaveProperty('username');
      expect(res.body.recent.registrations[0]).not.toHaveProperty('passwordHash');
    }
  });

  it('exposes recent admin actions to ADMIN only', async () => {
    const adminRes = await get('/admin/dashboard', admin.accessToken);
    expect(Array.isArray(adminRes.body.recent.audit)).toBe(true);

    const modRes = await get('/admin/dashboard', moderator.accessToken);
    expect(modRes.body.recent.audit).toBeNull();

    const expected = await prisma().adminAuditLog.count();
    expect(adminRes.body.recent.audit.length).toBe(Math.min(6, expected));
  });
});

/** Both seeded in-window users must appear on their exact registration day. */
async function expectSeededUsersRegistered(
  series: Array<{ date: string; count: number }>,
): Promise<void> {
  const byDate = Object.fromEntries(series.map((row) => [row.date, row.count]));
  for (const day of [DAY_OLD, DAY_RECENT]) {
    const expected = await prisma().user.count({
      where: { deletedAt: null, createdAt: { gte: dayStart(day), lt: nextDayStart(day) } },
    });
    expect(byDate[day]).toBe(expected);
    expect(expected).toBeGreaterThanOrEqual(1);
  }
}
