import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createHash } from 'node:crypto';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, auth, registerUser } from '../helpers/fixtures';
import { PrismaService } from '../../src/prisma/prisma.service';
import { WalletService } from '../../src/wallet/wallet.service';
import {
  CATALOG,
  findProduct,
} from '../../src/shop/catalog';

const COINS_100 = 'com.aatamgt.coins_100';
const COINS_1000 = 'com.aatamgt.coins_1000';
const COINS_5500 = 'com.aatamgt.coins_5500';
const ROYAL_PASS = 'com.aatamgt.royal_pass';

type TestUser = Awaited<ReturnType<typeof registerUser>>;

describe('In-app purchases (integration)', () => {
  let app: INestApplication;
  let prisma: PrismaService;
  let wallet: WalletService;
  let carol: TestUser;
  let dave: TestUser;
  let erin: TestUser;

  const api = () => app.getHttpServer();

  beforeAll(async () => {
    app = await createTestApp();
    prisma = app.get(PrismaService);
    wallet = app.get(WalletService);
    [carol, dave, erin] = await Promise.all([
      registerUser(app),
      registerUser(app),
      registerUser(app),
    ]);
  });

  afterAll(async () => {
    await app.close();
  });

  async function issue(user: TestUser, productId: string): Promise<string> {
    const res = await request(api())
      .post(`${apiPrefix(app)}/shop/dev/issue`)
      .set(auth(user.accessToken))
      .send({ productId });
    expect(res.status).toBe(200);
    return res.body.purchaseToken as string;
  }

  async function submit(user: TestUser, productId: string, purchaseToken: string) {
    return request(api())
      .post(`${apiPrefix(app)}/purchases`)
      .set(auth(user.accessToken))
      .send({ productId, purchaseToken });
  }

  async function balanceOf(user: TestUser): Promise<number> {
    const res = await request(api())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(user.accessToken));
    expect(res.status).toBe(200);
    return res.body.balance as number;
  }

  async function entitlements(user: TestUser) {
    const res = await request(api())
      .get(`${apiPrefix(app)}/shop/entitlements`)
      .set(auth(user.accessToken));
    expect(res.status).toBe(200);
    return res.body as { active: boolean; expiresAt: string | null };
  }

  function rtdnBody(payload: object) {
    return {
      message: { data: Buffer.from(JSON.stringify(payload)).toString('base64') },
    };
  }

  async function pushRtdn(payload: object) {
    return request(api())
      .post(`${apiPrefix(app)}/hooks/rtdn`)
      .send(rtdnBody(payload));
  }

  async function setStoreState(token: string, state: string) {
    const res = await request(api())
      .post(`${apiPrefix(app)}/shop/dev/store/${token}/state`)
      .set(auth(carol.accessToken))
      .send({ state });
    expect(res.status).toBe(200);
  }

  // --- Catalog ---------------------------------------------------------------

  it('serves the seven platform products without prices', async () => {
    const res = await request(api()).get(`${apiPrefix(app)}/shop/products`);
    expect(res.status).toBe(200);
    expect(res.body.devStore).toBe(true);
    const items = res.body.items as Array<Record<string, unknown>>;
    expect(items).toHaveLength(7);
    expect(items.map((i) => i.productKey)).toEqual(CATALOG.map((p) => p.productKey));
    const coins = items.filter((i) => i.kind === 'COINS');
    expect(coins.map((i) => i.coins)).toEqual([100, 1000, 5500, 12000, 65000, 150000]);
    const pass = items.find((i) => i.productKey === ROYAL_PASS)!;
    expect(pass.kind).toBe('ROYAL_PASS');
    expect(pass.passDays).toBe(30);
    // Prices never live on catalog items — the store client owns them.
    for (const item of items) {
      expect(item).not.toHaveProperty('price');
      expect(item).not.toHaveProperty('priceText');
      expect(item).not.toHaveProperty('priceMicros');
    }
    // The dev store simulator exposes fixture prices separately.
    expect(res.body.prices).toBeTruthy();
    expect(res.body.prices[ROYAL_PASS]).toBeTruthy();
    // Every product key is a platform-style ID.
    for (const item of items) {
      expect(String(item.productKey)).toMatch(/^com\.aatamgt\./);
    }
  });

  it('rejects unauthenticated purchase submission', async () => {
    const res = await request(api())
      .post(`${apiPrefix(app)}/purchases`)
      .send({ productId: COINS_100, purchaseToken: 'x' });
    expect(res.status).toBe(401);
  });

  // --- Verification + grant --------------------------------------------------

  it('grants coins only after store verification', async () => {
    const before = await balanceOf(carol);
    expect(before).toBe(1000);
    const token = await issue(carol, COINS_1000);
    const res = await submit(carol, COINS_1000, token);
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('granted');
    expect(res.body.purchase.state).toBe('GRANTED');
    expect(res.body.purchase.orderId).toMatch(/^dev\.order\./);
    expect(res.body.coinsBalance).toBe(before + 1000);
    const after = await balanceOf(carol);
    expect(after).toBe(2000);
    const row = await prisma.purchase.findFirst({ where: { purchaseToken: token } });
    expect(row?.coinAmount).toBe(1000);
    expect(row?.state).toBe('GRANTED');
    const txs = await prisma.walletTransaction.findMany({
      where: { idempotencyKey: row ? `iap:GOOGLE_PLAY:${hashOf(token)}` : '__none__' },
    });
    expect(txs).toHaveLength(1);
    expect(txs[0].type).toBe('PURCHASE');
    expect(txs[0].amount).toBe(1000);
  });

  it('is idempotent when the same store token is resubmitted', async () => {
    const token = await issue(carol, COINS_100);
    const first = await submit(carol, COINS_100, token);
    expect(first.body.status).toBe('granted');
    const balanceAfterFirst = await balanceOf(carol);
    const replay = await submit(carol, COINS_100, token);
    expect(replay.status).toBe(200);
    expect(replay.body.status).toBe('already_processed');
    expect(replay.body.coinsBalance).toBe(balanceAfterFirst);
    expect(await balanceOf(carol)).toBe(balanceAfterFirst);
    const rows = await prisma.purchase.count({ where: { purchaseToken: token } });
    expect(rows).toBe(1);
    const credits = await prisma.walletTransaction.count({
      where: { idempotencyKey: `iap:GOOGLE_PLAY:${hashOf(token)}` },
    });
    expect(credits).toBe(1);
  });

  it('rejects a token the store never issued', async () => {
    const before = await balanceOf(carol);
    const garbage = `garbage_${uniqueSuffix()}`;
    const res = await submit(carol, COINS_100, garbage);
    expect(res.status).toBe(422);
    expect(await balanceOf(carol)).toBe(before);
    const rows = await prisma.purchase.count({ where: { purchaseToken: garbage } });
    expect(rows).toBe(0);
  });

  it('rejects a token minted for a different product', async () => {
    const before = await balanceOf(carol);
    const token = await issue(carol, COINS_100);
    const res = await submit(carol, COINS_5500, token);
    expect(res.status).toBe(422);
    expect(await balanceOf(carol)).toBe(before);
  });

  it('rejects a token owned by another user', async () => {
    const token = await issue(carol, COINS_100);
    const before = await balanceOf(dave);
    const res = await submit(dave, COINS_100, token);
    expect(res.status).toBe(422);
    expect(await balanceOf(dave)).toBe(before);
    const rows = await prisma.purchase.count({ where: { purchaseToken: token } });
    expect(rows).toBe(0);
  });

  it('rejects unknown products and platforms', async () => {
    const token = await issue(carol, COINS_100);
    const unknownProduct = await submit(carol, 'com.aatamgt.nope', token);
    expect(unknownProduct.status).toBe(404);
    // The StoreKit seam answers "not wired up" instead of trusting anything.
    const apple = await request(api())
      .post(`${apiPrefix(app)}/purchases`)
      .set(auth(carol.accessToken))
      .send({ productId: COINS_100, purchaseToken: token, platform: 'APPLE_APP_STORE' });
    expect(apple.status).toBe(503);
    const badPlatform = await request(api())
      .post(`${apiPrefix(app)}/purchases`)
      .set(auth(carol.accessToken))
      .send({ productId: COINS_100, purchaseToken: token, platform: 'NINTENDO' });
    expect(badPlatform.status).toBe(400);
  });

  it('records pending store purchases without granting', async () => {
    const token = await issue(carol, COINS_100);
    await setStoreState(token, 'PENDING');
    const before = await balanceOf(carol);
    const res = await submit(carol, COINS_100, token);
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('pending');
    expect(res.body.purchase.state).toBe('PENDING');
    expect(await balanceOf(carol)).toBe(before);
  });

  // --- Restore ---------------------------------------------------------------

  it('restores unprocessed store tokens and is idempotent on repeat', async () => {
    const t1 = await issue(dave, COINS_100);
    const t2 = await issue(dave, ROYAL_PASS);
    const res = await request(api())
      .post(`${apiPrefix(app)}/purchases/restore`)
      .set(auth(dave.accessToken))
      .send({
        items: [
          { productId: COINS_100, purchaseToken: t1 },
          { productId: ROYAL_PASS, purchaseToken: t2 },
        ],
      });
    expect(res.status).toBe(200);
    expect((res.body.results as Array<{ status: string }>).map((r) => r.status)).toEqual([
      'granted',
      'granted',
    ]);
    expect(res.body.coinsBalance).toBe(1100);
    expect(res.body.royalPass.active).toBe(true);

    const again = await request(api())
      .post(`${apiPrefix(app)}/purchases/restore`)
      .set(auth(dave.accessToken))
      .send({
        items: [
          { productId: COINS_100, purchaseToken: t1 },
          { productId: ROYAL_PASS, purchaseToken: t2 },
        ],
      });
    expect((again.body.results as Array<{ status: string }>).map((r) => r.status)).toEqual([
      'already_processed',
      'already_processed',
    ]);
    expect(again.body.coinsBalance).toBe(1100);
    expect(await prisma.purchase.count({ where: { userId: dave.id } })).toBe(2);
  });

  it('rejects invalid tokens during restore without failing the batch', async () => {
    const good = await issue(erin, COINS_1000);
    const res = await request(api())
      .post(`${apiPrefix(app)}/purchases/restore`)
      .set(auth(erin.accessToken))
      .send({
        items: [
          { productId: COINS_1000, purchaseToken: good },
          { productId: COINS_100, purchaseToken: `bogus_${uniqueSuffix()}` },
        ],
      });
    expect(res.status).toBe(200);
    const results = res.body.results as Array<{ status: string }>;
    expect(results[0].status).toBe('granted');
    expect(results[1].status).toBe('rejected');
    expect(res.body.coinsBalance).toBe(2000);
  });

  // --- Royal Pass ------------------------------------------------------------

  it('grants a 30-day Royal Pass and stacks the next purchase on top', async () => {
    const t1 = await issue(erin, ROYAL_PASS);
    const first = await submit(erin, ROYAL_PASS, t1);
    expect(first.status).toBe(200);
    expect(first.body.status).toBe('granted');
    expect(first.body.royalPass.active).toBe(true);
    const e1 = new Date(first.body.royalPass.expiresAt as string).getTime();
    expect(e1).toBeGreaterThan(Date.now() + 29 * 86_400_000);
    expect(e1).toBeLessThanOrEqual(Date.now() + 31 * 86_400_000);
    // Pass purchases never touch the wallet.
    expect(first.body.coinsBalance).toBe(2000);

    const t2 = await issue(erin, ROYAL_PASS);
    const second = await submit(erin, ROYAL_PASS, t2);
    const e2 = new Date(second.body.royalPass.expiresAt as string).getTime();
    expect(e2).toBeGreaterThanOrEqual(e1 + 29 * 86_400_000);
    expect(e2).toBeLessThanOrEqual(e1 + 31 * 86_400_000);
    expect(await balanceOf(erin)).toBe(2000);

    const status = await entitlements(erin);
    expect(status.active).toBe(true);
    expect(status.expiresAt).toBe(second.body.royalPass.expiresAt);
  });

  it('treats a past-dated pass as expired', async () => {
    await prisma.user.update({
      where: { id: erin.id },
      data: { royalPassExpiresAt: new Date(Date.now() - 60_000) },
    });
    const status = await entitlements(erin);
    expect(status.active).toBe(false);
    expect(status.expiresAt).toBeTruthy();
  });

  // --- Refunds / revocations -------------------------------------------------

  let refundedToken = '';
  let frankUser: TestUser;

  it('applies a refund: claws back coins and marks the purchase REFUNDED', async () => {
    frankUser = await registerUser(app);
    refundedToken = await issue(frankUser, COINS_1000);
    const grant = await submit(frankUser, COINS_1000, refundedToken);
    expect(grant.body.status).toBe('granted');
    expect(await balanceOf(frankUser)).toBe(2000);

    const notify = await pushRtdn({
      oneTimeProductNotification: { notificationType: 11, purchaseToken: refundedToken },
    });
    expect(notify.status).toBe(200);
    expect(await balanceOf(frankUser)).toBe(1000);
    const row = await prisma.purchase.findFirst({
      where: { purchaseToken: refundedToken },
    });
    expect(row?.state).toBe('REFUNDED');
    expect(row?.revocationReason).toBe('rtdn_refunded');

    const repeat = await pushRtdn({
      oneTimeProductNotification: { notificationType: 11, purchaseToken: refundedToken },
    });
    expect(repeat.body.actions[0].status).toBe('already_refunded');
    expect(await balanceOf(frankUser)).toBe(1000);
  });

  it('re-credits when the store later reports the purchase good again', async () => {
    const notify = await pushRtdn({
      oneTimeProductNotification: { notificationType: 4, purchaseToken: refundedToken },
    });
    expect(notify.status).toBe(200);
    expect(notify.body.actions[0].action).toBe('recovered');
    const row = await prisma.purchase.findFirst({
      where: { purchaseToken: refundedToken },
    });
    expect(row?.state).toBe('GRANTED');
    expect(row?.revokedAt).toBeNull();
    // Refund took 1000 away, recovery credits it exactly once more.
    expect(await balanceOf(frankUser)).toBe(2000);
  });

  it('floors the clawback at zero when the coins were already spent', async () => {
    const gina = await registerUser(app);
    const token = await issue(gina, COINS_100);
    await submit(gina, COINS_100, token);
    await wallet.debit(gina.id, 1100, {
      type: 'ADMIN_ADJUSTMENT',
      memo: 'drain before refund floor test',
    });
    expect(await balanceOf(gina)).toBe(0);
    const notify = await pushRtdn({
      oneTimeProductNotification: { notificationType: 11, purchaseToken: token },
    });
    expect(notify.body.actions[0].status).toBe('revoked');
    expect(await balanceOf(gina)).toBe(0);
    const row = await prisma.purchase.findFirst({ where: { purchaseToken: token } });
    expect(row?.state).toBe('REFUNDED');
  });

  it('ignores cancellations but rolls the pass back on revocation', async () => {
    const harry = await registerUser(app);
    const token = await issue(harry, ROYAL_PASS);
    await submit(harry, ROYAL_PASS, token);
    expect((await entitlements(harry)).active).toBe(true);

    const cancelled = await pushRtdn({
      subscriptionNotification: { notificationType: 3, purchaseToken: token },
    });
    expect(cancelled.body.actions[0].action).toBe('cancel_acknowledged');
    expect((await entitlements(harry)).active).toBe(true);

    const revoked = await pushRtdn({
      subscriptionNotification: { notificationType: 12, purchaseToken: token },
    });
    expect(revoked.body.actions[0].status).toBe('revoked');
    const status = await entitlements(harry);
    expect(status.active).toBe(false);
    expect(status.expiresAt).toBeNull();
    const row = await prisma.purchase.findFirst({ where: { purchaseToken: token } });
    expect(row?.state).toBe('REVOKED');
    expect(row?.revocationReason).toBe('rtdn_revoked');
  });

  it('extends the pass on a renewal notification', async () => {
    const ivy = await registerUser(app);
    const token = await issue(ivy, ROYAL_PASS);
    const grant = await submit(ivy, ROYAL_PASS, token);
    const e1 = new Date(grant.body.royalPass.expiresAt as string).getTime();
    const renew = await pushRtdn({
      subscriptionNotification: { notificationType: 2, purchaseToken: token },
    });
    expect(renew.body.actions[0].action).toBe('renewed');
    const status = await entitlements(ivy);
    expect(status.active).toBe(true);
    const e2 = new Date(status.expiresAt as string).getTime();
    expect(e2).toBeGreaterThanOrEqual(e1 + 29 * 86_400_000);
    expect(e2).toBeLessThanOrEqual(e1 + 31 * 86_400_000);
  });

  it('expires the pass through the EXPIRED notification', async () => {
    const jack = await registerUser(app);
    const token = await issue(jack, ROYAL_PASS);
    await submit(jack, ROYAL_PASS, token);
    const notify = await pushRtdn({
      subscriptionNotification: { notificationType: 6, purchaseToken: token },
    });
    expect(notify.body.actions[0].status).toBe('revoked');
    expect((await entitlements(jack)).active).toBe(false);
    const row = await prisma.purchase.findFirst({ where: { purchaseToken: token } });
    expect(row?.state).toBe('EXPIRED');
    expect(row?.revocationReason).toBe('rtdn_expired');
  });

  // --- History ---------------------------------------------------------------

  it('lists verified purchases for the account', async () => {
    const res = await request(api())
      .get(`${apiPrefix(app)}/purchases`)
      .set(auth(erin.accessToken));
    expect(res.status).toBe(200);
    const items = res.body.items as Array<{ productKey: string; state: string }>;
    expect(items.length).toBeGreaterThanOrEqual(3);
    for (const item of items) {
      expect(findProduct(item.productKey)).toBeTruthy();
      expect(['GRANTED', 'PENDING', 'REFUNDED', 'REVOKED', 'EXPIRED']).toContain(item.state);
    }
  });

  // __PART2__

  function hashOf(token: string): string {
    // Matches ShopService.walletKey's sha256 hex encoding.
    return createHash('sha256').update(token).digest('hex');
  }
});
