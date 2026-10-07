import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  createGameFixture,
  createUserDirectly,
  prisma,
  registerUser,
  TestUser,
} from '../helpers/fixtures';

const ADS_ENV_KEYS = [
  'ADS_PROVIDER',
  'ADS_REWARDED_UNIT_ID',
  'ADS_INTERSTITIAL_UNIT_ID',
  'ADS_SESSION_TTL_SECONDS',
  'ADS_INTERSTITIAL_AFTER_WINS',
  'ADS_INTERSTITIAL_AFTER_LOSSES',
  'ADS_INTERSTITIAL_COOLDOWN_MATCHES',
] as const;

const OPPOSITE: Record<'WIN' | 'LOSS' | 'DRAW', 'WIN' | 'LOSS' | 'DRAW'> = {
  WIN: 'LOSS',
  LOSS: 'WIN',
  DRAW: 'DRAW',
};

describe('Ad architecture (Phase 8)', () => {
  let app: INestApplication;

  const openSession = (target: INestApplication, token: string, tier = 'BONUS') =>
    request(target.getHttpServer())
      .post(`${apiPrefix(target)}/ads/rewarded/session`)
      .set(auth(token))
      .send({ tier });

  const redeem = (
    target: INestApplication,
    token: string,
    nonce: string,
    payload?: Record<string, unknown>,
  ) =>
    request(target.getHttpServer())
      .post(`${apiPrefix(target)}/ads/rewarded/redeem`)
      .set(auth(token))
      .send(payload ? { nonce, payload } : { nonce });

  const walletBalance = async (target: INestApplication, token: string) => {
    const res = await request(target.getHttpServer())
      .get(`${apiPrefix(target)}/wallet`)
      .set(auth(token));
    return res.body.balance as number;
  };

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  describe('rewarded flow — server-minted sessions only', () => {
    it('mints a session bound to the server-chosen provider and TTL', async () => {
      const user = await registerUser(app);
      const res = await openSession(app, user.accessToken, 'BONUS');
      expect(res.status).toBe(200);
      expect(res.body.provider).toBe('stub');
      expect(res.body.tier).toBe('BONUS');
      expect(typeof res.body.nonce).toBe('string');
      expect(res.body.nonce.length).toBeGreaterThanOrEqual(32);
      const ttl = (new Date(res.body.expiresAt).getTime() - Date.now()) / 1000;
      expect(ttl).toBeGreaterThan(290);
      expect(ttl).toBeLessThanOrEqual(300);
    });

    it('pays a redeemed session exactly the configured tier amount', async () => {
      const user = await registerUser(app);
      const session = await openSession(app, user.accessToken, 'BONUS');
      const res = await redeem(app, user.accessToken, session.body.nonce);
      expect(res.status).toBe(200);
      expect(res.body).toMatchObject({ tier: 'BONUS', coins: 500, balance: 1500, replayed: false });
      expect(typeof res.body.transactionId).toBe('string');
    });

    it('never pays a fabricated nonce and leaves the ledger untouched', async () => {
      const user = await registerUser(app);
      const fabricated = 'x'.repeat(32);

      const res = await redeem(app, user.accessToken, fabricated);
      expect(res.status).toBe(404);
      expect(await walletBalance(app, user.accessToken)).toBe(1000);

      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      expect(txs.body.items.filter((row: { type: string }) => row.type === 'REWARDED_AD')).toHaveLength(0);
    });

    it("rejects another user's nonce with the same 404 (no existence oracle)", async () => {
      const alice = await registerUser(app);
      const bob = await registerUser(app);
      const session = await openSession(app, alice.accessToken);

      const res = await redeem(app, bob.accessToken, session.body.nonce);
      expect(res.status).toBe(404);
      expect(await walletBalance(app, bob.accessToken)).toBe(1000);

      // Alice can still redeem her own session.
      const own = await redeem(app, alice.accessToken, session.body.nonce);
      expect(own.status).toBe(200);
      expect(own.body.coins).toBe(500);
    });

    it('rejects an expired session with 410 and pays nothing', async () => {
      const user = await registerUser(app);
      const session = await openSession(app, user.accessToken);
      await prisma().adSession.update({
        where: { nonce: session.body.nonce as string },
        data: { expiresAt: new Date(Date.now() - 1000) },
      });

      const res = await redeem(app, user.accessToken, session.body.nonce);
      expect(res.status).toBe(410);
      expect(await walletBalance(app, user.accessToken)).toBe(1000);
    });

    it('ignores a client-sent amount and pays only the configured tier', async () => {
      const user = await registerUser(app);
      const session = await openSession(app, user.accessToken, 'STANDARD');
      const res = await redeem(app, user.accessToken, session.body.nonce, {
        coins: 999999,
        amount: 999999,
        tier: 'BONUS',
      });
      expect(res.status).toBe(200);
      expect(res.body.coins).toBe(100);
      expect(res.body.balance).toBe(1100);
      expect(await walletBalance(app, user.accessToken)).toBe(1100);
    });

    it('rejects an unknown or missing tier at session creation', async () => {
      const user = await registerUser(app);
      const unknown = await openSession(app, user.accessToken, 'MEGA');
      expect(unknown.status).toBe(400);
      const missing = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/ads/rewarded/session`)
        .set(auth(user.accessToken))
        .send({});
      expect(missing.status).toBe(400);
    });

    it('rejects a redeem that omits the nonce', async () => {
      const user = await registerUser(app);
      const res = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/ads/rewarded/redeem`)
        .set(auth(user.accessToken))
        .send({ payload: { anything: true } });
      expect(res.status).toBe(400);
    });

    it('credits exactly once when one session is redeemed concurrently', async () => {
      const user = await registerUser(app);
      const session = await openSession(app, user.accessToken, 'BONUS');

      const responses = await Promise.all(
        [0, 1, 2, 3, 4].map(() => redeem(app, user.accessToken, session.body.nonce)),
      );
      for (const res of responses) expect([200, 409]).toContain(res.status);
      expect(responses.filter((r) => r.status === 200 && r.body.replayed === false)).toHaveLength(1);

      expect(await walletBalance(app, user.accessToken)).toBe(1500);
      const txs = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/wallet/transactions`)
        .set(auth(user.accessToken));
      expect(txs.body.items.filter((row: { type: string }) => row.type === 'REWARDED_AD')).toHaveLength(1);
    });
  });

  describe('server-driven config', () => {
    it('exposes provider, empty unit IDs and the configured rules', async () => {
      const user = await registerUser(app);
      const res = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/ads/config`)
        .set(auth(user.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.provider).toBe('stub');
      expect(res.body.rewardedUnitId).toBe('');
      expect(res.body.interstitialUnitId).toBe('');
      expect(res.body.sessionTtlSeconds).toBe(300);
      expect(res.body.rewardedTiers).toEqual({ BONUS: 500, STANDARD: 100 });
      expect(res.body.interstitial).toEqual({ afterWins: 3, afterLosses: 5, cooldownMatches: 2 });
    });

    it('requires authentication on every ads endpoint', async () => {
      const calls = [
        request(app.getHttpServer()).get(`${apiPrefix(app)}/ads/config`),
        request(app.getHttpServer()).post(`${apiPrefix(app)}/ads/rewarded/session`).send({ tier: 'BONUS' }),
        request(app.getHttpServer()).post(`${apiPrefix(app)}/ads/rewarded/redeem`).send({ nonce: 'x' }),
        request(app.getHttpServer()).get(`${apiPrefix(app)}/ads/interstitial/eligibility`),
        request(app.getHttpServer()).post(`${apiPrefix(app)}/ads/interstitial/shown`).send({}),
      ];
      const responses = await Promise.all(calls);
      for (const res of responses) expect(res.status).toBe(401);
    });
  });

  describe('interstitial eligibility (server-side rules)', () => {
    let subject: TestUser;
    let opponent: { id: string };
    let gameId: string;
    let gameKey: string;
    let offset = 0;
    const T0 = Date.now() - 3_600_000;

    const seedCompleted = async (
      result: 'WIN' | 'LOSS' | 'DRAW',
      at = (offset += 1000),
    ): Promise<string> => {
      const match = await prisma().gameMatch.create({
        data: {
          gameId,
          gameKey,
          status: 'COMPLETED',
          mode: 'CASUAL',
          startedAt: new Date(T0 + at - 60_000),
          completedAt: new Date(T0 + at),
          players: {
            create: [
              { userId: subject.id, seat: 0, result },
              { userId: opponent.id, seat: 1, result: OPPOSITE[result] },
            ],
          },
        },
      });
      return match.id;
    };

    const seedActive = async (): Promise<string> => {
      const match = await prisma().gameMatch.create({
        data: {
          gameId,
          gameKey,
          status: 'ACTIVE',
          mode: 'CASUAL',
          startedAt: new Date(T0 + 9_000_000),
          players: {
            create: [
              { userId: subject.id, seat: 0, result: 'PENDING' },
              { userId: opponent.id, seat: 1, result: 'PENDING' },
            ],
          },
        },
      });
      return match.id;
    };

    const resetHistory = async () => {
      const rows = await prisma().gameMatch.findMany({
        where: { players: { some: { userId: subject.id } } },
        select: { id: true },
      });
      await prisma().gameMatch.deleteMany({ where: { id: { in: rows.map((r) => r.id) } } });
      await prisma().adShow.deleteMany({ where: { userId: subject.id } });
      offset = 0;
    };

    const eligibility = async () => {
      const res = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/ads/interstitial/eligibility`)
        .set(auth(subject.accessToken));
      expect(res.status).toBe(200);
      return res.body as {
        eligible: boolean;
        reason: string;
        winsSinceLastShow: number;
        consecutiveLosses: number;
        matchesSinceLastShow: number;
      };
    };

    const show = (body: Record<string, unknown>) =>
      request(app.getHttpServer())
        .post(`${apiPrefix(app)}/ads/interstitial/shown`)
        .set(auth(subject.accessToken))
        .send(body);

    beforeAll(async () => {
      subject = await registerUser(app);
      opponent = await createUserDirectly(`opp_${uniqueSuffix()}`.slice(0, 24), 'USER');
      gameKey = await createGameFixture();
      const game = await prisma().game.findUnique({ where: { key: gameKey } });
      gameId = game!.id;
    });

    it('is NOT_YET for a fresh player', async () => {
      await resetHistory();
      const verdict = await eligibility();
      expect(verdict).toMatchObject({ eligible: false, reason: 'NOT_YET', winsSinceLastShow: 0 });
    });

    it('stays NOT_YET with two wins and fires on the third', async () => {
      await resetHistory();
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      expect(await eligibility()).toMatchObject({ eligible: false, reason: 'NOT_YET' });

      await seedCompleted('WIN');
      expect(await eligibility()).toMatchObject({ eligible: true, reason: 'WINS' });
    });

    it('stays NOT_YET at four consecutive losses and fires on the fifth', async () => {
      await resetHistory();
      for (let i = 0; i < 4; i++) await seedCompleted('LOSS');
      expect(await eligibility()).toMatchObject({ eligible: false, reason: 'NOT_YET' });

      await seedCompleted('LOSS');
      expect(await eligibility()).toMatchObject({ eligible: true, reason: 'LOSSES' });
    });

    it('breaks the consecutive-loss streak with a draw', async () => {
      await resetHistory();
      for (let i = 0; i < 5; i++) await seedCompleted('LOSS');
      await seedCompleted('DRAW');
      const verdict = await eligibility();
      expect(verdict.consecutiveLosses).toBe(0);
      expect(verdict).toMatchObject({ eligible: false, reason: 'NOT_YET' });
    });

    it('blocks with a match in progress even when wins are due', async () => {
      await resetHistory();
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      await seedActive();
      expect(await eligibility()).toMatchObject({ eligible: false, reason: 'IN_PROGRESS' });
    });

    it('blocks royal pass users and releases them when it expires', async () => {
      await resetHistory();
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      await seedCompleted('WIN');

      await prisma().user.update({
        where: { id: subject.id },
        data: { royalPassExpiresAt: new Date(Date.now() + 30 * 86_400_000) },
      });
      expect(await eligibility()).toMatchObject({ eligible: false, reason: 'ROYAL_PASS' });

      await prisma().user.update({
        where: { id: subject.id },
        data: { royalPassExpiresAt: new Date(Date.now() - 1_000) },
      });
      expect(await eligibility()).toMatchObject({ eligible: true, reason: 'WINS' });

      await prisma().user.update({
        where: { id: subject.id },
        data: { royalPassExpiresAt: null },
      });
    });

    it('resets the window after a reported interstitial show', async () => {
      await resetHistory();
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      await seedCompleted('WIN');
      expect(await eligibility()).toMatchObject({ eligible: true, reason: 'WINS' });

      const shown = await show({});
      expect(shown.status).toBe(200);
      expect(new Date(shown.body.shownAt).toString()).not.toBe('Invalid Date');

      expect(await eligibility()).toMatchObject({
        eligible: false,
        reason: 'NOT_YET',
        winsSinceLastShow: 0,
        matchesSinceLastShow: 0,
      });
    });

    it('records the shown ack against the caller-owned match', async () => {
      const matchId = await seedCompleted('WIN');
      const shown = await show({ matchId });
      expect(shown.status).toBe(200);

      const row = await prisma().adShow.findFirst({
        where: { userId: subject.id, kind: 'INTERSTITIAL', matchId },
        orderBy: { shownAt: 'desc' },
      });
      expect(row).not.toBeNull();
    });

    it('rejects a shown ack for an unknown match', async () => {
      const res = await show({ matchId: 'match_does_not_exist' });
      expect(res.status).toBe(400);
    });
  });

  describe('env-configured provider and thresholds', () => {
    let cfgApp: INestApplication;
    const saved: Record<string, string | undefined> = {};

    beforeAll(async () => {
      for (const key of ADS_ENV_KEYS) saved[key] = process.env[key];
      process.env.ADS_PROVIDER = 'admob';
      process.env.ADS_REWARDED_UNIT_ID = 'unit-test-rewarded';
      process.env.ADS_INTERSTITIAL_UNIT_ID = 'unit-test-interstitial';
      process.env.ADS_INTERSTITIAL_AFTER_WINS = '1';
      process.env.ADS_INTERSTITIAL_AFTER_LOSSES = '5';
      process.env.ADS_INTERSTITIAL_COOLDOWN_MATCHES = '2';
      cfgApp = await createTestApp();
    });

    afterAll(async () => {
      await cfgApp.close();
      for (const key of ADS_ENV_KEYS) {
        if (saved[key] === undefined) delete process.env[key];
        else process.env[key] = saved[key];
      }
    });

    it('serves the configured unit IDs and thresholds', async () => {
      const user = await registerUser(cfgApp);
      const res = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/ads/config`)
        .set(auth(user.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.provider).toBe('admob');
      expect(res.body.rewardedUnitId).toBe('unit-test-rewarded');
      expect(res.body.interstitialUnitId).toBe('unit-test-interstitial');
      expect(res.body.interstitial).toEqual({ afterWins: 1, afterLosses: 5, cooldownMatches: 2 });
    });

    it('applies the configured cooldown before the first eligible win', async () => {
      const user = await registerUser(cfgApp);
      const opponent = await createUserDirectly(`opp_${uniqueSuffix()}`.slice(0, 24), 'USER');
      const gameKey = await createGameFixture();
      const game = await prisma().game.findUnique({ where: { key: gameKey } });
      const at = Date.now() - 3_600_000;

      const seedWin = async (offsetMs: number) =>
        prisma().gameMatch.create({
          data: {
            gameId: game!.id,
            gameKey,
            status: 'COMPLETED',
            mode: 'CASUAL',
            startedAt: new Date(at + offsetMs - 60_000),
            completedAt: new Date(at + offsetMs),
            players: {
              create: [
                { userId: user.id, seat: 0, result: 'WIN' },
                { userId: opponent.id, seat: 1, result: 'LOSS' },
              ],
            },
          },
        });

      await seedWin(0);
      let res = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/ads/interstitial/eligibility`)
        .set(auth(user.accessToken));
      expect(res.body).toMatchObject({ eligible: false, reason: 'COOLDOWN' });

      await seedWin(1000);
      res = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/ads/interstitial/eligibility`)
        .set(auth(user.accessToken));
      expect(res.body).toMatchObject({ eligible: true, reason: 'WINS' });
    });

    it('mints sessions for the configured provider and refuses to pay without a verifier', async () => {
      const user = await registerUser(cfgApp);
      const session = await request(cfgApp.getHttpServer())
        .post(`${apiPrefix(cfgApp)}/ads/rewarded/session`)
        .set(auth(user.accessToken))
        .send({ tier: 'BONUS' });
      expect(session.status).toBe(200);
      expect(session.body.provider).toBe('admob');

      const res = await request(cfgApp.getHttpServer())
        .post(`${apiPrefix(cfgApp)}/ads/rewarded/redeem`)
        .set(auth(user.accessToken))
        .send({ nonce: session.body.nonce });
      expect(res.status).toBe(503);

      const balance = await request(cfgApp.getHttpServer())
        .get(`${apiPrefix(cfgApp)}/wallet`)
        .set(auth(user.accessToken));
      expect(balance.body.balance).toBe(1000);
    });
  });
});
