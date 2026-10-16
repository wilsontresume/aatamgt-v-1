import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  createGameFixture,
  createUserDirectly,
  login,
  prisma,
  registerUser,
} from '../helpers/fixtures';
import { WalletService } from '../../src/wallet/wallet.service';

type TestUser = Awaited<ReturnType<typeof registerUser>>;

interface ConfigItem {
  key: string;
  label: string;
  kind: 'int' | 'bool';
  min: number | null;
  max: number | null;
  value: number | boolean;
  default: number | boolean;
  overridden: boolean;
}

describe('Admin dashboard (Phase 15)', () => {
  let app: INestApplication;
  let adminToken: string;
  let moderatorToken: string;
  let adminId: string;
  let player: TestUser;
  let opponent: TestUser;

  const api = () => app.getHttpServer();
  const get = (path: string, token?: string) => {
    const req = request(api()).get(`${apiPrefix(app)}${path}`);
    return token ? req.set(auth(token)) : req;
  };
  const put = (path: string, body: unknown, token = adminToken) =>
    request(api()).put(`${apiPrefix(app)}${path}`).set(auth(token)).send(body as object);
  const patch = (path: string, body: unknown, token = adminToken) =>
    request(api()).patch(`${apiPrefix(app)}${path}`).set(auth(token)).send(body as object);

  async function configItems(token = adminToken): Promise<ConfigItem[]> {
    const res = await get('/admin/config', token);
    expect(res.status).toBe(200);
    return res.body.items as ConfigItem[];
  }

  async function configValue(key: string): Promise<number | boolean> {
    const items = await configItems();
    const entry = items.find((row) => row.key === key);
    expect(entry).toBeDefined();
    return entry!.value;
  }

  async function putConfig(entries: Array<{ key: string; value: unknown }>) {
    return put('/admin/config', { entries });
  }

  async function restore(pairs: Array<{ key: string; value: unknown }>) {
    const res = await putConfig(pairs);
    expect(res.status).toBe(200);
  }

  beforeAll(async () => {
    app = await createTestApp();
    const admin = await createUserDirectly(`adm_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const mod = await createUserDirectly(`mod_${uniqueSuffix()}`.slice(0, 24), 'MODERATOR');
    const adminLogin = await login(app, admin.username, admin.password);
    const modLogin = await login(app, mod.username, mod.password);
    expect(adminLogin.status).toBe(200);
    expect(modLogin.status).toBe(200);
    adminToken = adminLogin.body.accessToken as string;
    moderatorToken = modLogin.body.accessToken as string;
    adminId = admin.id;
    player = await registerUser(app);
    opponent = await registerUser(app);
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  // --- Authz ----------------------------------------------------------------

  it('blocks anonymous and regular users from dashboard reads', async () => {
    for (const path of ['/admin/economy/summary', '/admin/config', '/admin/cosmetics']) {
      expect((await get(path)).status).toBe(401);
      expect((await get(path, player.accessToken)).status).toBe(403);
    }
    expect((await get(`/admin/users/${player.id}`)).status).toBe(401);
    expect((await get(`/admin/users/${player.id}`, player.accessToken)).status).toBe(403);
  });

  it('blocks regular users from every admin action', async () => {
    const actions = [
      patch(`/admin/users/${opponent.id}/status`, { status: 'SUSPENDED' }, player.accessToken),
      put('/admin/config', { entries: [{ key: 'coins.daily_reward', value: 1 }] }, player.accessToken),
      patch('/admin/cosmetics/any', { price: 1 }, player.accessToken),
      request(api())
        .post(`${apiPrefix(app)}/admin/wallets/${opponent.id}/adjust`)
        .set(auth(player.accessToken))
        .send({ amount: 1, reason: 'should never land' }),
    ];
    for (const res of await Promise.all(actions)) {
      expect(res.status).toBe(403);
    }
  });

  it('lets moderators read but never mutate', async () => {
    expect((await get('/admin/config', moderatorToken)).status).toBe(200);
    expect((await get('/admin/economy/summary', moderatorToken)).status).toBe(200);
    expect((await get('/admin/cosmetics', moderatorToken)).status).toBe(200);
    expect(
      (await get('/admin/users', moderatorToken)).status,
    ).toBe(200);

    const readsOnly = await Promise.all([
      put('/admin/config', { entries: [{ key: 'coins.daily_reward', value: 1 }] }, moderatorToken),
      patch('/admin/cosmetics/whatever', { price: 1 }, moderatorToken),
      patch(`/admin/users/${opponent.id}/status`, { status: 'SUSPENDED' }, moderatorToken),
      get('/admin/audit', moderatorToken),
    ]);
    for (const res of readsOnly) expect(res.status).toBe(403);
  });

  // --- Players --------------------------------------------------------------

  it('returns full player detail with profile and wallets', async () => {
    const res = await get(`/admin/users/${player.id}`, adminToken);
    expect(res.status).toBe(200);
    expect(res.body.username).toBe(player.username);
    expect(res.body.role).toBe('USER');
    expect(res.body.status).toBe('ACTIVE');
    expect(res.body.profile.displayName).toBe(player.username);
    expect(Array.isArray(res.body.wallets)).toBe(true);
    expect(res.body.wallets[0].balance).toBeGreaterThanOrEqual(1000);

    const missing = await get('/admin/users/does-not-exist', adminToken);
    expect(missing.status).toBe(404);
  });

  it('lists the player wallet ledger with the registration bonus', async () => {
    const res = await get(`/admin/users/${player.id}/wallet`, adminToken);
    expect(res.status).toBe(200);
    expect(res.body.balance).toBeGreaterThanOrEqual(1000);
    expect(res.body.total).toBeGreaterThanOrEqual(1);
    expect(
      (res.body.items as Array<{ type: string }>).some((row) => row.type === 'REGISTRATION_BONUS'),
    ).toBe(true);
  });

  it('shows admin wallet adjustments in the ledger and the audit log', async () => {
    const before = await get(`/admin/users/${player.id}/wallet`, adminToken);
    const beforeBalance = before.body.balance as number;

    const adjust = await request(api())
      .post(`${apiPrefix(app)}/admin/wallets/${player.id}/adjust`)
      .set(auth(adminToken))
      .send({ amount: 250, reason: 'phase 15 dashboard grant' });
    expect(adjust.status).toBe(201);
    expect(adjust.body.balance).toBe(beforeBalance + 250);

    const wallet = await get(`/admin/users/${player.id}/wallet`, adminToken);
    const top = (wallet.body.items as Array<{ type: string; amount: number }>)[0];
    expect(top.type).toBe('ADMIN_ADJUSTMENT');
    expect(top.amount).toBe(250);

    const audit = await get('/admin/audit?limit=100', adminToken);
    const entry = (audit.body.items as Array<{ action: string; targetId: string }>).find(
      (row) => row.action === 'wallet.adjust' && row.targetId === player.id,
    );
    expect(entry).toBeDefined();
  });

  it('shows match history for a player', async () => {
    const gameKey = await createGameFixture();
    const game = await prisma().game.findUniqueOrThrow({ where: { key: gameKey } });
    const match = await prisma().gameMatch.create({
      data: {
        gameId: game.id,
        gameKey: game.key,
        status: 'ACTIVE',
        startedAt: new Date(),
        createdByUserId: player.id,
        players: {
          create: [
            { userId: player.id, seat: 0 },
            { userId: opponent.id, seat: 1 },
          ],
        },
      },
    });

    const history = await get(`/admin/users/${player.id}/matches`, adminToken);
    expect(history.status).toBe(200);
    const listed = (history.body.items as Array<{ id: string }>).find((row) => row.id === match.id);
    expect(listed).toBeDefined();

    const finalised = await patch(`/admin/matches/${match.id}/finalize`, {
      status: 'COMPLETED',
      reason: 'phase 15 history test',
      players: [
        { userId: player.id, result: 'WIN', score: 1 },
        { userId: opponent.id, result: 'LOSS', score: 0 },
      ],
    });
    expect(finalised.status).toBe(200);

    const after = await get(`/admin/users/${player.id}/matches?limit=100`, adminToken);
    const row = (after.body.items as Array<{ id: string; status: string; players: unknown[] }>).find(
      (item) => item.id === match.id,
    );
    expect(row?.status).toBe('COMPLETED');
    expect(Array.isArray(row?.players)).toBe(true);
    expect(row?.players.length).toBe(2);
  });

  it('suspends a player, blocks their login, then unbans', async () => {
    const victim = await registerUser(app);

    const suspended = await patch(`/admin/users/${victim.id}/status`, {
      status: 'SUSPENDED',
      reason: 'phase 15 suspension test',
    });
    expect(suspended.status).toBe(200);
    expect(suspended.body.status).toBe('SUSPENDED');

    const blocked = await login(app, victim.username, victim.password);
    expect(blocked.status).toBeGreaterThanOrEqual(401);
    expect(blocked.status).toBeLessThan(500);

    const audit = await get('/admin/audit?limit=100', adminToken);
    const entry = (audit.body.items as Array<{ action: string; targetId: string }>).find(
      (row) => row.action === 'user.status' && row.targetId === victim.id,
    );
    expect(entry).toBeDefined();

    const restored = await patch(`/admin/users/${victim.id}/status`, { status: 'ACTIVE' });
    expect(restored.status).toBe(200);
    const allowed = await login(app, victim.username, victim.password);
    expect(allowed.status).toBe(200);
  });

  it('bans a player, blocks their login, then unbans', async () => {
    const victim = await registerUser(app);

    const banned = await patch(`/admin/users/${victim.id}/status`, {
      status: 'BANNED',
      reason: 'phase 15 ban test',
    });
    expect(banned.status).toBe(200);
    expect(banned.body.status).toBe('BANNED');

    const blocked = await login(app, victim.username, victim.password);
    expect(blocked.status).toBeGreaterThanOrEqual(401);
    expect(blocked.status).toBeLessThan(500);

    const restored = await patch(`/admin/users/${victim.id}/status`, { status: 'ACTIVE' });
    expect(restored.status).toBe(200);
    expect((await login(app, victim.username, victim.password)).status).toBe(200);
  });

  it('refuses to let an admin suspend themselves', async () => {
    const res = await patch(`/admin/users/${adminId}/status`, { status: 'SUSPENDED' });
    expect(res.status).toBe(400);
  });
  // --- Games ----------------------------------------------------------------

  it('filters matches by status for the games tab', async () => {
    const gameKey = await createGameFixture();
    const game = await prisma().game.findUniqueOrThrow({ where: { key: gameKey } });
    const match = await prisma().gameMatch.create({
      data: {
        gameId: game.id,
        gameKey: game.key,
        status: 'ACTIVE',
        startedAt: new Date(),
        createdByUserId: opponent.id,
        players: {
          create: [
            { userId: opponent.id, seat: 0 },
            { userId: player.id, seat: 1 },
          ],
        },
      },
    });

    const active = await get('/admin/matches?status=ACTIVE&limit=100', adminToken);
    expect(active.status).toBe(200);
    expect(
      (active.body.items as Array<{ id: string }>).some((row) => row.id === match.id),
    ).toBe(true);

    const finalised = await patch(`/admin/matches/${match.id}/finalize`, {
      status: 'ABANDONED',
      reason: 'phase 15 games tab test',
      players: [
        { userId: opponent.id, result: 'ABANDONED', score: 0 },
        { userId: player.id, result: 'ABANDONED', score: 0 },
      ],
    });
    expect(finalised.status).toBe(200);

    const abandoned = await get('/admin/matches?status=ABANDONED&limit=100', adminToken);
    expect(abandoned.status).toBe(200);
    expect(
      (abandoned.body.items as Array<{ id: string }>).some((row) => row.id === match.id),
    ).toBe(true);

    const stillActive = await get('/admin/matches?status=ACTIVE&limit=100', adminToken);
    expect(
      (stillActive.body.items as Array<{ id: string }>).some((row) => row.id === match.id),
    ).toBe(false);

    const invalid = await get('/admin/matches?status=NOT_A_STATUS', adminToken);
    expect(invalid.status).toBe(400);
  });

  // --- Economy --------------------------------------------------------------

  it('summarises coins issued, transactions and rewarded ads', async () => {
    const res = await get('/admin/economy/summary', adminToken);
    expect(res.status).toBe(200);
    expect(res.body.coinsIssued).toBeGreaterThanOrEqual(3000);
    expect(res.body.coinsSpent).toBeGreaterThanOrEqual(0);
    expect(res.body.transactions).toBeGreaterThanOrEqual(3);
    expect(res.body.rewardedAds).toBeDefined();
    expect(typeof res.body.rewardedAds.coinsGranted).toBe('number');
    expect(res.body.purchases).toBeDefined();
    expect(typeof res.body.purchases.count).toBe('number');
  });

  it('records a real dev-store purchase in the economy views', async () => {
    const issue = await request(api())
      .post(`${apiPrefix(app)}/shop/dev/issue`)
      .set(auth(player.accessToken))
      .send({ productId: 'com.aatamgt.coins_100' });
    expect(issue.status).toBe(200);

    const submit = await request(api())
      .post(`${apiPrefix(app)}/purchases`)
      .set(auth(player.accessToken))
      .send({
        productId: 'com.aatamgt.coins_100',
        purchaseToken: issue.body.purchaseToken,
      });
    expect(submit.status).toBeLessThan(300);
    expect(submit.body.status).toBe('granted');

    const summary = await get('/admin/economy/summary', adminToken);
    expect(summary.body.purchases.byState.GRANTED).toBeGreaterThanOrEqual(1);

    const purchases = await get('/admin/economy/purchases?limit=100', adminToken);
    expect(purchases.status).toBe(200);
    const listed = (
      purchases.body.items as Array<{ productKey: string; username: string; state: string }>
    ).find(
      (row) =>
        row.productKey === 'com.aatamgt.coins_100' &&
        row.username === player.username &&
        row.state === 'GRANTED',
    );
    expect(listed).toBeDefined();

    const txns = await get(
      `/admin/economy/transactions?userId=${player.id}&type=PURCHASE&limit=100`,
      adminToken,
    );
    expect(txns.status).toBe(200);
    expect(
      (txns.body.items as Array<{ amount: number }>).some((row) => row.amount === 100),
    ).toBe(true);
  });

  it('tracks rewarded ad grants in the summary and the ledger', async () => {
    const wallet = app.get(WalletService);
    const result = await wallet.credit(player.id, 424, {
      type: 'REWARDED_AD',
      refType: 'rewarded_ad',
      refId: 'BONUS',
      idempotencyKey: `p15-ad-${uniqueSuffix()}`,
      memo: 'Phase 15 dashboard rewarded ad test',
    });
    expect(result.replayed).toBe(false);

    const summary = await get('/admin/economy/summary', adminToken);
    expect(summary.body.rewardedAds.grants).toBeGreaterThanOrEqual(1);
    expect(summary.body.rewardedAds.coinsGranted).toBeGreaterThanOrEqual(424);

    const txns = await get('/admin/economy/transactions?type=REWARDED_AD&limit=100', adminToken);
    expect(txns.status).toBe(200);
    expect(
      (txns.body.items as Array<{ amount: number; type: string }>).some(
        (row) => row.amount === 424 && row.type === 'REWARDED_AD',
      ),
    ).toBe(true);
  });

  it('lists interstitial ad shows with player names', async () => {
    await prisma().adShow.create({
      data: { userId: player.id, kind: 'INTERSTITIAL' },
    });
    const res = await get('/admin/economy/ads?limit=100', adminToken);
    expect(res.status).toBe(200);
    expect(
      (res.body.items as Array<{ username: string; kind: string }>).some(
        (row) => row.username === player.username && row.kind === 'INTERSTITIAL',
      ),
    ).toBe(true);
  });

  it('rejects unknown transaction filters with 400', async () => {
    const res = await get('/admin/economy/transactions?type=NOT_A_TYPE', adminToken);
    expect(res.status).toBe(400);
  });

  // --- Content --------------------------------------------------------------

  it('lists cosmetics with ownership counts', async () => {
    const res = await get('/admin/cosmetics?limit=100', adminToken);
    expect(res.status).toBe(200);
    expect(res.body.total).toBeGreaterThanOrEqual(1);
    const first = (
      res.body.items as Array<{
        key: string;
        category: string;
        price: number;
        active: boolean;
        owners: number;
      }>
    )[0];
    expect(typeof first.key).toBe('string');
    expect(typeof first.category).toBe('string');
    expect(typeof first.price).toBe('number');
    expect(typeof first.active).toBe('boolean');
    expect(typeof first.owners).toBe('number');
  });

  it('filters the cosmetics list by category', async () => {
    const res = await get('/admin/cosmetics?category=BOARD_SKIN&limit=100', adminToken);
    expect(res.status).toBe(200);
    expect(res.body.items.length).toBeGreaterThan(0);
    for (const row of res.body.items as Array<{ category: string }>) {
      expect(row.category).toBe('BOARD_SKIN');
    }
    const invalid = await get('/admin/cosmetics?category=HAT', adminToken);
    expect(invalid.status).toBe(400);
  });

  it('updates a cosmetic price and reflects it in the public catalog', async () => {
    const list = await get('/admin/cosmetics?limit=100', adminToken);
    const target = (list.body.items as Array<{ id: string; key: string; price: number }>).find(
      (row) => row.price >= 0,
    )!;
    const originalPrice = target.price;
    try {
      const patched = await patch(`/admin/cosmetics/${target.id}`, { price: 123 });
      expect(patched.status).toBe(200);
      expect(patched.body.price).toBe(123);

      const audit = await get('/admin/audit?limit=100', adminToken);
      const entry = (audit.body.items as Array<{ action: string; targetId: string }>).find(
        (row) => row.action === 'cosmetic.update' && row.targetId === target.id,
      );
      expect(entry).toBeDefined();

      const publicList = await get('/cosmetics', player.accessToken);
      expect(publicList.status).toBe(200);
      const shown = (publicList.body.items as Array<{ key: string; price: number }>).find(
        (row) => row.key === target.key,
      );
      expect(shown?.price).toBe(123);
    } finally {
      expect((await patch(`/admin/cosmetics/${target.id}`, { price: originalPrice })).status).toBe(
        200,
      );
    }
  });

  it('disables a cosmetic so it leaves the public catalog, then re-enables', async () => {
    const list = await get('/admin/cosmetics?limit=100', adminToken);
    const target = (
      list.body.items as Array<{ id: string; key: string; active: boolean }>
    ).find((row) => row.active)!;
    try {
      const disabled = await patch(`/admin/cosmetics/${target.id}`, { active: false });
      expect(disabled.status).toBe(200);
      expect(disabled.body.active).toBe(false);

      const publicList = await get('/cosmetics', player.accessToken);
      expect(
        (publicList.body.items as Array<{ key: string }>).some((row) => row.key === target.key),
      ).toBe(false);

      const adminList = await get('/admin/cosmetics?limit=100', adminToken);
      const shown = (adminList.body.items as Array<{ id: string; active: boolean }>).find(
        (row) => row.id === target.id,
      );
      expect(shown?.active).toBe(false);
    } finally {
      expect((await patch(`/admin/cosmetics/${target.id}`, { active: true })).status).toBe(200);
    }

    const restoredList = await get('/cosmetics', player.accessToken);
    expect(
      (restoredList.body.items as Array<{ key: string }>).some((row) => row.key === target.key),
    ).toBe(true);
  });

  it('validates cosmetic patches', async () => {
    expect((await patch('/admin/cosmetics/nope', { price: 1 })).status).toBe(404);
    const list = await get('/admin/cosmetics?limit=1', adminToken);
    const target = (list.body.items as Array<{ id: string }>)[0];
    expect((await patch(`/admin/cosmetics/${target.id}`, { price: -5 })).status).toBe(400);
    expect((await patch(`/admin/cosmetics/${target.id}`, {})).status).toBe(400);
  });

  // --- Configuration --------------------------------------------------------

  it('exposes every config key with kinds, bounds and defaults', async () => {
    const items = await configItems();
    const keys = items.map((row) => row.key);
    for (const key of [
      'coins.registration_bonus',
      'coins.daily_reward',
      'ads.rewarded_bonus',
      'ads.rewarded_standard',
      'ads.interstitial_after_wins',
      'ads.interstitial_after_losses',
      'ads.interstitial_cooldown_matches',
      'shop.royal_pass_days',
      'shop.royal_pass_enabled',
    ]) {
      expect(keys).toContain(key);
    }
    const bonus = items.find((row) => row.key === 'coins.registration_bonus')!;
    expect(bonus.kind).toBe('int');
    expect(bonus.min).toBe(0);
    expect(bonus.max).toBe(1_000_000);
    expect(typeof bonus.value).toBe('number');
    const pass = items.find((row) => row.key === 'shop.royal_pass_enabled')!;
    expect(pass.kind).toBe('bool');
    expect(typeof pass.value).toBe('boolean');
  });

  it('rejects invalid config writes without applying anything', async () => {
    const before = await configValue('coins.registration_bonus');

    const range = await putConfig([{ key: 'coins.registration_bonus', value: 999_999_999 }]);
    expect(range.status).toBe(400);
    const type = await putConfig([{ key: 'coins.registration_bonus', value: true }]);
    expect(type.status).toBe(400);
    const unknown = await putConfig([{ key: 'coins.unknown_thing', value: 1 }]);
    expect(unknown.status).toBe(400);

    expect(await configValue('coins.registration_bonus')).toBe(before);
  });

  it('applies a registration bonus override end-to-end and audits it', async () => {
    const original = await configValue('coins.registration_bonus');
    let fresh: TestUser | undefined;
    try {
      const res = await putConfig([{ key: 'coins.registration_bonus', value: 777 }]);
      expect(res.status).toBe(200);
      const entry = (res.body.items as ConfigItem[]).find(
        (row) => row.key === 'coins.registration_bonus',
      );
      expect(entry?.value).toBe(777);

      fresh = await registerUser(app);
      const wallet = await get(`/admin/users/${fresh.id}/wallet`, adminToken);
      expect(wallet.body.balance).toBe(777);

      const audit = await get('/admin/audit?limit=100', adminToken);
      const entryLog = (audit.body.items as Array<{ action: string; data: unknown }>).find(
        (row) => row.action === 'config.set',
      );
      expect(entryLog).toBeDefined();
      const changes = (entryLog!.data as { changes: Array<{ key: string; before: unknown; after: unknown }> })
        .changes;
      expect(changes.some((c) => c.key === 'coins.registration_bonus' && c.after === 777)).toBe(
        true,
      );
    } finally {
      await restore([{ key: 'coins.registration_bonus', value: original }]);
    }
    expect(await configValue('coins.registration_bonus')).toBe(original);
  });

  it('drives the public ads config from overrides', async () => {
    const bonusOriginal = await configValue('ads.rewarded_bonus');
    const winsOriginal = await configValue('ads.interstitial_after_wins');
    try {
      expect(
        (await putConfig([
          { key: 'ads.rewarded_bonus', value: 654 },
          { key: 'ads.interstitial_after_wins', value: 7 },
        ])).status,
      ).toBe(200);

      const adsConfig = await get('/ads/config', player.accessToken);
      expect(adsConfig.status).toBe(200);
      expect(adsConfig.body.rewardedTiers.BONUS).toBe(654);
      expect(adsConfig.body.interstitial.afterWins).toBe(7);
    } finally {
      await restore([
        { key: 'ads.rewarded_bonus', value: bonusOriginal },
        { key: 'ads.interstitial_after_wins', value: winsOriginal },
      ]);
    }
    expect(await configValue('ads.rewarded_bonus')).toBe(bonusOriginal);
  });

  it('drives Royal Pass days and availability from overrides', async () => {
    const daysOriginal = await configValue('shop.royal_pass_days');
    const enabledOriginal = await configValue('shop.royal_pass_enabled');
    try {
      expect(
        (await putConfig([{ key: 'shop.royal_pass_days', value: 45 }])).status,
      ).toBe(200);
      let catalog = await get('/shop/products', player.accessToken);
      const pass = (catalog.body.items as Array<{ productKey: string; passDays: number; title: string }>).find(
        (row) => row.productKey === 'com.aatamgt.royal_pass',
      );
      expect(pass).toBeDefined();
      expect(pass?.passDays).toBe(45);
      expect(pass?.title).toContain('(45 days)');

      expect(
        (await putConfig([{ key: 'shop.royal_pass_enabled', value: false }])).status,
      ).toBe(200);
      catalog = await get('/shop/products', player.accessToken);
      expect(
        (catalog.body.items as Array<{ productKey: string }>).some(
          (row) => row.productKey === 'com.aatamgt.royal_pass',
        ),
      ).toBe(false);
      const issue = await request(api())
        .post(`${apiPrefix(app)}/shop/dev/issue`)
        .set(auth(player.accessToken))
        .send({ productId: 'com.aatamgt.royal_pass' });
      expect(issue.status).toBe(400);
    } finally {
      await restore([
        { key: 'shop.royal_pass_days', value: daysOriginal },
        { key: 'shop.royal_pass_enabled', value: enabledOriginal },
      ]);
    }
    const catalog = await get('/shop/products', player.accessToken);
    expect(
      (catalog.body.items as Array<{ productKey: string }>).some(
        (row) => row.productKey === 'com.aatamgt.royal_pass',
      ),
    ).toBe(true);
  });

  // --- Audit ----------------------------------------------------------------

  it('returns the full audit trail to admins with actor names', async () => {
    const res = await get('/admin/audit?limit=100', adminToken);
    expect(res.status).toBe(200);
    expect(res.body.total).toBeGreaterThanOrEqual(1);
    const items = res.body.items as Array<{ action: string; actor: string; createdAt: string }>;
    expect(items[0].actor).toBeTruthy();
    expect(typeof items[0].createdAt).toBe('string');
    const actions = new Set(items.map((row) => row.action));
    for (const action of [
      'user.status',
      'wallet.adjust',
      'match.finalize',
      'cosmetic.update',
      'config.set',
    ]) {
      expect(actions.has(action)).toBe(true);
    }
  });
});
