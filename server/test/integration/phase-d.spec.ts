import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';

jest.setTimeout(40_000);

const THRESHOLD_KEY = 'admin.wallet_adjust_threshold';
const DEFAULT_THRESHOLD = 100_000;

const utcToday = (): string => new Date().toISOString().slice(0, 10);

describe('Phase D — economy management', () => {
  let app: INestApplication;
  let api: string;
  let admin: TestUser;
  let mod: TestUser;
  let player: TestUser;

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  const adjust = (actor: TestUser, body: Record<string, unknown>, userId?: string) =>
    request(app.getHttpServer())
      .post(`${api}/admin/wallets/${userId ?? player.id}/adjust`)
      .set(auth(actor.accessToken))
      .send(body);

  const balanceOf = async (): Promise<number> => {
    const res = await request(app.getHttpServer())
      .get(`${api}/admin/users/${player.id}/wallet`)
      .set(auth(admin.accessToken));
    expect(res.status).toBe(200);
    return res.body.balance as number;
  };

  const setThreshold = async (value: number) => {
    const res = await request(app.getHttpServer())
      .put(`${api}/admin/config`)
      .set(auth(admin.accessToken))
      .send({ entries: [{ key: THRESHOLD_KEY, value }] });
    expect(res.status).toBe(200);
  };

  const thresholdEntry = async (): Promise<{ value: number; overridden: boolean }> => {
    const res = await request(app.getHttpServer())
      .get(`${api}/admin/config`)
      .set(auth(admin.accessToken));
    expect(res.status).toBe(200);
    return res.body.items.find((row: { key: string }) => row.key === THRESHOLD_KEY);
  };

  beforeAll(async () => {
    app = await createTestApp();
    api = apiPrefix(app);
    admin = await registerUser(app, { role: 'ADMIN', username: `pd_${uniqueSuffix()}`.slice(0, 24) });
    mod = await registerUser(app, { role: 'MODERATOR', username: `pd_${uniqueSuffix()}`.slice(0, 24) });
    player = await registerUser(app, { username: `pd_${uniqueSuffix()}`.slice(0, 24) });
    await setThreshold(DEFAULT_THRESHOLD);
  });

  afterAll(async () => {
    // Leave the shared config and audit table as they were found.
    await setThreshold(DEFAULT_THRESHOLD);
    await prisma().adminAuditLog.deleteMany({
      where: { actorUserId: { in: [admin.id, mod.id] } },
    });
    await app.close();
    await closePrisma();
  });

  describe('mandatory reasons', () => {
    it('rejects a missing or blank reason without touching the balance', async () => {
      const before = await balanceOf();

      const missing = await adjust(admin, { amount: 5 });
      expect(missing.status).toBe(400);

      const blank = await adjust(admin, { amount: 5, reason: '   ' });
      expect(blank.status).toBe(400);

      expect(await balanceOf()).toBe(before);
    });

    it('stores the reason on the ledger row and in the audit entry', async () => {
      const before = await balanceOf();
      const reason = `Phase D reason ${uniqueSuffix()}`;

      const res = await adjust(admin, { amount: 250, reason });
      expect(res.status).toBe(201);
      expect(res.body.balance).toBe(before + 250);
      expect(res.body.replayed).toBe(false);
      expect(res.body.large).toBe(false);

      const wallet = await request(app.getHttpServer())
        .get(`${api}/admin/users/${player.id}/wallet`)
        .set(auth(admin.accessToken));
      expect(wallet.body.items[0].type).toBe('ADMIN_ADJUSTMENT');
      expect(wallet.body.items[0].memo).toBe(reason);

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit?limit=100`)
        .set(auth(admin.accessToken));
      const entry = audit.body.items.find(
        (row: { action: string; targetId: string }) =>
          row.action === 'wallet.adjust' && row.targetId === player.id,
      );
      expect(entry).toBeDefined();
      expect(entry.data.reason).toBe(reason);
      expect(entry.data.large).toBe(false);
    });

    it('rejects zero and non-integer amounts', async () => {
      expect((await adjust(admin, { amount: 0, reason: 'zero' })).status).toBe(400);
      expect((await adjust(admin, { amount: 1.5, reason: 'fraction' })).status).toBe(400);
    });
  });

  describe('insufficient balance', () => {
    it('rejects an overdrawn debit with 422 and leaves the wallet untouched', async () => {
      const before = await balanceOf();
      const res = await adjust(admin, { amount: -1_000_000, reason: 'Phase D overdraw' });
      expect(res.status).toBe(422);
      expect(await balanceOf()).toBe(before);
    });

    it('accepts a debit that keeps the balance non-negative', async () => {
      const before = await balanceOf();
      const res = await adjust(admin, { amount: -100, reason: 'Phase D clawback' });
      expect(res.status).toBe(201);
      expect(res.body.balance).toBe(before - 100);
    });
  });

  describe('configurable large-adjustment threshold', () => {
    afterAll(async () => {
      await setThreshold(DEFAULT_THRESHOLD);
    });

    it('is exposed through the config API with its bounds', async () => {
      await setThreshold(500);
      const entry = await thresholdEntry();
      expect(entry.value).toBe(500);
      expect(entry.overridden).toBe(true);

      const bad = await request(app.getHttpServer())
        .put(`${api}/admin/config`)
        .set(auth(admin.accessToken))
        .send({ entries: [{ key: THRESHOLD_KEY, value: 0 }] });
      expect(bad.status).toBe(400);
    });

    it('lets a moderator adjust below the threshold', async () => {
      const before = await balanceOf();
      const res = await adjust(mod, { amount: 400, reason: 'Phase D small mod correction' });
      expect(res.status).toBe(201);
      expect(res.body.balance).toBe(before + 400);
      expect(res.body.large).toBe(false);
    });

    it('blocks a moderator at or above the threshold, in both directions', async () => {
      const before = await balanceOf();

      const credit = await adjust(mod, { amount: 500, reason: 'Phase D large mod credit' });
      expect(credit.status).toBe(403);
      expect(credit.body.message).toMatch(/restricted to administrators/i);

      const debit = await adjust(mod, { amount: -500, reason: 'Phase D large mod debit' });
      expect(debit.status).toBe(403);

      expect(await balanceOf()).toBe(before);
    });

    it('allows an administrator at the threshold and flags the audit entry', async () => {
      const before = await balanceOf();
      const reason = `Phase D large admin credit ${uniqueSuffix()}`;
      const res = await adjust(admin, { amount: 500, reason });
      expect(res.status).toBe(201);
      expect(res.body.large).toBe(true);
      expect(res.body.balance).toBe(before + 500);

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit?limit=100`)
        .set(auth(admin.accessToken));
      const entry = audit.body.items.find(
        (row: { action: string; targetId: string; data: { amount?: number } }) =>
          row.action === 'wallet.adjust' &&
          row.targetId === player.id &&
          row.data.amount === 500,
      );
      expect(entry).toBeDefined();
      expect(entry.data.large).toBe(true);
    });

    it('clears the override when reset to the default', async () => {
      await setThreshold(DEFAULT_THRESHOLD);
      const entry = await thresholdEntry();
      expect(entry.value).toBe(DEFAULT_THRESHOLD);
      expect(entry.overridden).toBe(false);
    });
  });

  describe('duplicate and concurrent requests', () => {
    it('replays an identical idempotent submission instead of double-applying', async () => {
      const before = await balanceOf();
      const idempotencyKey = `pd-dup-${uniqueSuffix()}`.replace(/[^A-Za-z0-9_-]/g, '');
      const body = { amount: 77, reason: 'Phase D duplicate probe', idempotencyKey };

      const first = await adjust(admin, body);
      expect(first.status).toBe(201);
      expect(first.body.replayed).toBe(false);

      const second = await adjust(admin, body);
      expect(second.status).toBe(201);
      expect(second.body.replayed).toBe(true);
      expect(second.body.transactionId).toBe(first.body.transactionId);
      expect(second.body.balance).toBe(first.body.balance);
      expect(await balanceOf()).toBe(before + 77);

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit?limit=100`)
        .set(auth(admin.accessToken));
      const entries = audit.body.items.filter(
        (row: { action: string; data: { amount?: number } }) =>
          row.action === 'wallet.adjust' && row.data.amount === 77,
      );
      expect(entries).toHaveLength(1);
    });

    it('rejects a malformed idempotency key', async () => {
      const res = await adjust(admin, {
        amount: 5,
        reason: 'Phase D bad key',
        idempotencyKey: 'no spaces allowed!!',
      });
      expect(res.status).toBe(400);
    });

    it('loses no updates when two adjustments race', async () => {
      const before = await balanceOf();
      const [a, b] = await Promise.all([
        adjust(admin, {
          amount: 13,
          reason: 'Phase D concurrent A',
          idempotencyKey: `pd-con-a-${uniqueSuffix()}`.replace(/[^A-Za-z0-9_-]/g, ''),
        }),
        adjust(admin, {
          amount: 17,
          reason: 'Phase D concurrent B',
          idempotencyKey: `pd-con-b-${uniqueSuffix()}`.replace(/[^A-Za-z0-9_-]/g, ''),
        }),
      ]);
      expect(a.status).toBe(201);
      expect(b.status).toBe(201);
      expect(await balanceOf()).toBe(before + 30);
    });
  });

  describe('authorization', () => {
    it('denies economy reads and adjustments to USER callers', async () => {
      expect(
        (await request(app.getHttpServer()).get(`${api}/admin/economy/summary`).set(auth(player.accessToken))).status,
      ).toBe(403);
      expect(
        (await request(app.getHttpServer()).get(`${api}/admin/economy/trends`).set(auth(player.accessToken))).status,
      ).toBe(403);
      expect((await adjust(player, { amount: 1, reason: 'not allowed' })).status).toBe(403);
    });

    it('denies anonymous callers', async () => {
      expect((await request(app.getHttpServer()).get(`${api}/admin/economy/summary`)).status).toBe(401);
    });

    it('lets moderators read every economy surface', async () => {
      for (const path of ['economy/summary', 'economy/transactions', 'economy/trends']) {
        const res = await request(app.getHttpServer())
          .get(`${api}/admin/${path}`)
          .set(auth(mod.accessToken));
        expect(res.status).toBe(200);
      }
    });
  });

  describe('date-filtered transactions', () => {
    it('includes and excludes rows by day', async () => {
      const reason = `Phase D date probe ${uniqueSuffix()}`;
      const created = await adjust(admin, { amount: 21, reason });
      expect(created.status).toBe(201);
      const txId = created.body.transactionId as string;
      const today = utcToday();

      const inRange = await request(app.getHttpServer())
        .get(`${api}/admin/economy/transactions`)
        .query({ from: today, to: today })
        .set(auth(admin.accessToken));
      expect(inRange.status).toBe(200);
      expect(inRange.body.items.some((row: { id: string }) => row.id === txId)).toBe(true);

      const outOfRange = await request(app.getHttpServer())
        .get(`${api}/admin/economy/transactions`)
        .query({ from: '2000-01-01', to: '2000-01-02' })
        .set(auth(admin.accessToken));
      expect(outOfRange.status).toBe(200);
      expect(outOfRange.body.items.some((row: { id: string }) => row.id === txId)).toBe(false);
    });

    it('filters by transaction type', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/economy/transactions`)
        .query({ type: 'ADMIN_ADJUSTMENT', limit: 5 })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      for (const row of res.body.items) expect(row.type).toBe('ADMIN_ADJUSTMENT');
    });

    it('rejects malformed and impossible dates', async () => {
      const malformed = await request(app.getHttpServer())
        .get(`${api}/admin/economy/transactions`)
        .query({ from: 'not-a-date', to: utcToday() })
        .set(auth(admin.accessToken));
      expect(malformed.status).toBe(400);

      const impossible = await request(app.getHttpServer())
        .get(`${api}/admin/economy/transactions`)
        .query({ from: '2026-02-31', to: utcToday() })
        .set(auth(admin.accessToken));
      expect(impossible.status).toBe(400);
    });
  });

  describe('trends', () => {
    it('returns a zero-filled daily series with activity today', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/economy/trends`)
        .query({ from: utcToday(), to: utcToday() })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.points).toHaveLength(1);
      const point = res.body.points[0];
      expect(point.day).toBe(utcToday());
      expect(point.transactions).toBeGreaterThanOrEqual(1);
      expect(point.issued).toBeGreaterThanOrEqual(21);
      expect(point.net).toBe(point.issued - point.spent);
    });

    it('defaults to the last 14 days', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/economy/trends`)
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.points).toHaveLength(14);
      expect(res.body.range.to).toBe(utcToday());
    });

    it('rejects an inverted range', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/economy/trends`)
        .query({ from: utcToday(), to: '2000-01-01' })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(400);
    });
  });

  describe('summary', () => {
    it('reports circulation, flows and purchases from real aggregates', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/economy/summary`)
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);

      const expected = await prisma().wallet.aggregate({
        where: { currency: 'COIN' },
        _sum: { balance: true, lockedBalance: true },
        _count: { _all: true },
      });
      expect(res.body.circulation.coins).toBe(expected._sum.balance ?? 0);
      expect(res.body.circulation.locked).toBe(expected._sum.lockedBalance ?? 0);
      expect(res.body.circulation.wallets).toBe(expected._count._all);

      expect(res.body.coinsIssued).toBeGreaterThanOrEqual(21);
      expect(res.body.coinsSpent).toBeGreaterThanOrEqual(100);
      expect(res.body.transactions).toBeGreaterThanOrEqual(1);
      expect(res.body.purchases).toHaveProperty('byState');
      expect(res.body.rewardedAds).toHaveProperty('sessions');
    });
  });
});
