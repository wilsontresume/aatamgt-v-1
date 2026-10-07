import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, auth, closePrisma, createUserDirectly, prisma, registerUser } from '../helpers/fixtures';

const COIN_ENV_KEYS = [
  'COINS_REGISTRATION_BONUS',
  'COINS_DAILY_LOGIN_BONUS',
  'COINS_REWARDED_AD_BONUS',
  'COINS_REWARDED_AD_STANDARD',
] as const;

describe('Virtual coins (Phase 7)', () => {
  let app: INestApplication;
  let adminToken: string;

  const postAd = (
    target: INestApplication,
    token: string,
    tier: string,
    idempotencyKey: string,
  ) =>
    request(target.getHttpServer())
      .post(`${apiPrefix(target)}/rewards/ad`)
      .set(auth(token))
      .send({ tier, idempotencyKey });

  beforeAll(async () => {
    app = await createTestApp();
    const admin = await createUserDirectly(`adm_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const login = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: admin.username, password: admin.password });
    expect(login.status).toBe(200);
    adminToken = login.body.accessToken;
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  describe('duplicate rewards', () => {
    it('pays a rewarded ad exactly once per idempotency key', async () => {
      const user = await registerUser(app);

      const first = await postAd(app, user.accessToken, 'BONUS', 'view-dup-0001');
      expect(first.status).toBe(200);
      expect(first.body.replayed).toBe(false);
      expect(first.body.coins).toBe(500);
      expect(first.body.balance).toBe(1500);

      const second = await postAd(app, user.accessToken, 'BONUS', 'view-dup-0001');
      expect(second.status).toBe(200);
      expect(second.body.replayed).toBe(true);
      expect(second.body.transactionId).toBe(first.body.transactionId);
      expect(second.body.balance).toBe(1500);

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      const adRows = txs.body.items.filter((row: { type: string }) => row.type === 'REWARDED_AD');
      expect(adRows).toHaveLength(1);
    });

    it('never double-pays a second daily claim for the same day', async () => {
      const user = await registerUser(app);

      const first = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/rewards/daily/claim`)
        .set(auth(user.accessToken));
      expect(first.status).toBe(200);
      expect(first.body.coins).toBe(100);

      const second = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/rewards/daily/claim`)
        .set(auth(user.accessToken));
      expect(second.status).toBe(409);

      const balance = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1100);
    });
  });

  describe('concurrent transactions', () => {
    it('lands every distinct-key credit submitted in parallel exactly once', async () => {
      const user = await registerUser(app);

      const responses = await Promise.all(
        [0, 1, 2, 3, 4].map((i) => postAd(app, user.accessToken, 'STANDARD', `view-par-${i}a`)),
      );
      for (const res of responses) expect(res.status).toBe(200);
      expect(responses.filter((r) => r.body.replayed === false)).toHaveLength(5);

      const balance = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1500); // 1000 + 5 × 100

      const integrity = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/integrity`)
        .set(auth(user.accessToken));
      expect(integrity.body.ok).toBe(true);
      expect(integrity.body.ledgerSum).toBe(1500);
      expect(integrity.body.transactionCount).toBe(6);
    });

    it('pays only once when the same key is submitted in parallel', async () => {
      const user = await registerUser(app);

      const responses = await Promise.all(
        [0, 1, 2, 3, 4].map(() => postAd(app, user.accessToken, 'BONUS', 'view-same-01')),
      );
      for (const res of responses) expect(res.status).toBe(200);

      const balance = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1500); // 1000 + exactly one 500

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      const adRows = txs.body.items.filter((row: { type: string }) => row.type === 'REWARDED_AD');
      expect(adRows).toHaveLength(1);
    });
  });

  describe('negative balance', () => {
    it('rejects a debit that would overdraw the wallet and leaves it untouched', async () => {
      const user = await registerUser(app);

      const adjust = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/admin/wallets/${user.id}/adjust`)
        .set(auth(adminToken))
        .send({ amount: -5000, memo: 'should never land' });
      expect(adjust.status).toBe(422);

      const balance = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1000);

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      expect(txs.body.items.some((row: { type: string }) => row.type === 'ADMIN_ADJUSTMENT')).toBe(
        false,
      );
    });

    it('accepts a negative adjustment that keeps the balance non-negative', async () => {
      const user = await registerUser(app);

      const adjust = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/admin/wallets/${user.id}/adjust`)
        .set(auth(adminToken))
        .send({ amount: -400, memo: 'phase 7 clawback' });
      expect(adjust.status).toBe(201);
      expect(adjust.body.balance).toBe(600);

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      const row = txs.body.items.find(
        (item: { type: string }) => item.type === 'ADMIN_ADJUSTMENT',
      );
      expect(row.amount).toBe(-400);
      expect(row.balanceAfter).toBe(600);
    });
  });

  describe('transaction replay', () => {
    it('replays to the original transaction without writing a new ledger row', async () => {
      const user = await registerUser(app);

      const first = await postAd(app, user.accessToken, 'STANDARD', 'view-replay-1');
      expect(first.body.replayed).toBe(false);

      const replay = await postAd(app, user.accessToken, 'STANDARD', 'view-replay-1');
      expect(replay.status).toBe(200);
      expect(replay.body.replayed).toBe(true);
      expect(replay.body.transactionId).toBe(first.body.transactionId);
      expect(replay.body.coins).toBe(first.body.coins);

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      // registration bonus + one ad credit — the replay added nothing
      expect(txs.body.total).toBe(2);

      const balance = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1100);
    });

    it('rejects replayed-shaped requests that omit the key', async () => {
      const user = await registerUser(app);
      const noKey = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/rewards/ad`)
        .set(auth(user.accessToken))
        .send({ tier: 'BONUS' });
      expect(noKey.status).toBe(400);
    });
  });

  describe('wallet consistency', () => {
    it('reports a consistent ledger after mixed activity', async () => {
      const user = await registerUser(app);

      await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/rewards/daily/claim`)
        .set(auth(user.accessToken));
      await postAd(app, user.accessToken, 'BONUS', 'view-mix-0001');
      await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/admin/wallets/${user.id}/adjust`)
        .set(auth(adminToken))
        .send({ amount: -200, memo: 'phase 7 mix' });

      const integrity = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/integrity`)
        .set(auth(user.accessToken));
      expect(integrity.status).toBe(200);
      expect(integrity.body.ok).toBe(true);
      expect(integrity.body.issues).toEqual([]);
      expect(integrity.body.ledgerSum).toBe(1400); // 1000 + 100 + 500 - 200
      expect(integrity.body.balance).toBe(1400);
      expect(integrity.body.transactionCount).toBe(4);
    });

    it('detects an out-of-band balance corruption', async () => {
      const user = await registerUser(app);

      await prisma().wallet.update({
        where: { userId_currency: { userId: user.id, currency: 'COIN' } },
        data: { balance: { increment: 1 } },
      });

      try {
        const integrity = await request(app.getHttpServer())
          .get(`${apiPrefix(app)}/wallet/integrity`)
          .set(auth(user.accessToken));
        expect(integrity.body.ok).toBe(false);
        expect(integrity.body.issues.length).toBeGreaterThan(0);
      } finally {
        // Restore the ledger so the shared test database stays consistent.
        await prisma().wallet.update({
          where: { userId_currency: { userId: user.id, currency: 'COIN' } },
          data: { balance: { decrement: 1 } },
        });
      }
    });

    it('requires authentication for the integrity endpoint', async () => {
      const res = await request(app.getHttpServer()).get(`${apiPrefix(app)}/wallet/integrity`);
      expect(res.status).toBe(401);
    });
  });

  describe('configurable initial values', () => {
    let cfgApp: INestApplication;
    const saved: Record<string, string | undefined> = {};

    beforeAll(async () => {
      for (const key of COIN_ENV_KEYS) saved[key] = process.env[key];
      process.env.COINS_REGISTRATION_BONUS = '777';
      process.env.COINS_DAILY_LOGIN_BONUS = '33';
      process.env.COINS_REWARDED_AD_BONUS = '888';
      process.env.COINS_REWARDED_AD_STANDARD = '44';
      cfgApp = await createTestApp();
    });

    afterAll(async () => {
      await cfgApp.close();
      for (const key of COIN_ENV_KEYS) {
        if (saved[key] === undefined) delete process.env[key];
        else process.env[key] = saved[key];
      }
    });

    it('pays every grant type from the configured amounts', async () => {
      const user = await registerUser(cfgApp);

      const balance = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(777);

      const daily = await request(cfgApp.getHttpServer())
        .post(`${apiPrefix(cfgApp)}/rewards/daily/claim`)
        .set(auth(user.accessToken));
      expect(daily.body.coins).toBe(33);
      expect(daily.body.balance).toBe(810);

      const bonus = await postAd(cfgApp, user.accessToken, 'BONUS', 'view-cfg-0001');
      expect(bonus.body.coins).toBe(888);

      const standard = await postAd(cfgApp, user.accessToken, 'STANDARD', 'view-cfg-0002');
      expect(standard.body.coins).toBe(44);
      expect(standard.body.balance).toBe(1742); // 777 + 33 + 888 + 44

      const integrity = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/wallet/integrity`)
        .set(auth(user.accessToken));
      expect(integrity.body.ok).toBe(true);
    });
  });
});
