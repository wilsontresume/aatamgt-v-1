import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';
import { CATALOG, CATEGORY_ORDER, DEFAULT_KEY_BY_CATEGORY } from '../../src/cosmetics/catalog';
import { WalletService } from '../../src/wallet/wallet.service';

/**
 * Phase 12 — server-owned cosmetic inventory.
 *
 * The test DB is migrated but never seeded, so this suite upserts the shared
 * catalog first. DEV grants default to ON outside production (NODE_ENV=test),
 * which the dev-grant cases rely on; cosmetics-dev-off.spec.ts covers the
 * disabled path.
 */
describe('Cosmetics inventory (integration)', () => {
  let app: INestApplication;
  let wallet: WalletService;

  const get = (user: TestUser, path: string) =>
    request(app.getHttpServer())
      .get(`${apiPrefix(app)}${path}`)
      .set(auth(user.accessToken));

  const post = (user: TestUser, path: string) =>
    request(app.getHttpServer())
      .post(`${apiPrefix(app)}${path}`)
      .set(auth(user.accessToken))
      .send({});

  beforeAll(async () => {
    for (const item of CATALOG) {
      await prisma().cosmetic.upsert({
        where: { key: item.key },
        update: {
          category: item.category,
          name: item.name,
          description: item.description,
          tier: item.tier,
          price: item.price,
          grantedByDefault: item.grantedByDefault,
          sortOrder: item.sortOrder,
          active: true,
        },
        create: item,
      });
    }
    app = await createTestApp();
    wallet = app.get(WalletService);
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  it('grants and equips every default cosmetic on first fetch', async () => {
    const user = await registerUser(app);
    const res = await get(user, '/cosmetics');

    expect(res.status).toBe(200);
    expect(res.body.devGrantsEnabled).toBe(true);
    expect(res.body.items).toHaveLength(CATALOG.length);

    const byKey = new Map<string, Record<string, any>>(
      res.body.items.map((item: any) => [item.key, item]),
    );
    for (const item of CATALOG) {
      const view = byKey.get(item.key);
      expect(view).toBeDefined();
      if (item.grantedByDefault) {
        expect(view!.owned).toBe(true);
        expect(view!.source).toBe('default');
      } else {
        expect(view!.owned).toBe(false);
        expect(view!.equipped).toBe(false);
        expect(view!.source).toBeUndefined();
      }
    }

    for (const category of CATEGORY_ORDER) {
      const equipped = res.body.items.filter(
        (item: any) => item.category === category && item.equipped,
      );
      expect(equipped).toHaveLength(1);
      expect(equipped[0].key).toBe(DEFAULT_KEY_BY_CATEGORY.get(category));
    }
  });

  it('stays stable on repeat fetches (no duplicate grants)', async () => {
    const user = await registerUser(app);
    const first = await get(user, '/cosmetics');
    const second = await get(user, '/cosmetics');

    expect(second.status).toBe(200);
    expect(second.body.items).toHaveLength(first.body.items.length);
    const ownedCount = second.body.items.filter((item: any) => item.owned).length;
    const defaults = CATALOG.filter((item) => item.grantedByDefault);
    expect(ownedCount).toBe(defaults.length);
  });

  it('publishes catalog tiers and prices for every item', async () => {
    const user = await registerUser(app);
    const res = await get(user, '/cosmetics');

    for (const seed of CATALOG) {
      const view = res.body.items.find((item: any) => item.key === seed.key);
      expect(view.tier).toBe(seed.tier);
      expect(view.price).toBe(seed.price);
      expect(view.category).toBe(seed.category);
      expect(view.name.length).toBeGreaterThan(0);
      if (seed.tier === 'FREE') expect(seed.price).toBe(0);
      else expect(seed.price).toBeGreaterThan(0);
    }
  });

  it('claims a free cosmetic exactly once', async () => {
    const user = await registerUser(app);

    const claim = await post(user, '/cosmetics/board_woodland/claim');
    expect(claim.status).toBe(200);
    expect(claim.body.item.owned).toBe(true);
    expect(claim.body.item.source).toBe('claim');
    expect(claim.body.item.equipped).toBe(false);

    const again = await post(user, '/cosmetics/board_woodland/claim');
    expect(again.status).toBe(409);

    const list = await get(user, '/cosmetics');
    const view = list.body.items.find((item: any) => item.key === 'board_woodland');
    expect(view.owned).toBe(true);
    expect(view.source).toBe('claim');
  });

  it('rejects claiming a premium cosmetic', async () => {
    const user = await registerUser(app);
    const res = await post(user, '/cosmetics/board_midnight/claim');
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toContain('Premium cosmetics must be purchased');
  });

  it('rejects purchasing a free cosmetic', async () => {
    const user = await registerUser(app);
    const res = await post(user, '/cosmetics/pfp_sunset/purchase');
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toContain('free');
  });

  it('keeps exactly one equipped cosmetic per category when switching', async () => {
    const user = await registerUser(app);
    await post(user, '/cosmetics/board_woodland/claim');
    const equipWoodland = await post(user, '/cosmetics/board_woodland/equip');
    expect(equipWoodland.status).toBe(200);
    expect(equipWoodland.body.item.equipped).toBe(true);

    let list = await get(user, '/cosmetics');
    expect(
      list.body.items.find((item: any) => item.key === 'board_woodland').equipped,
    ).toBe(true);
    expect(
      list.body.items.find((item: any) => item.key === 'board_classic').equipped,
    ).toBe(false);

    const equipClassic = await post(user, '/cosmetics/board_classic/equip');
    expect(equipClassic.status).toBe(200);

    list = await get(user, '/cosmetics');
    const equipped = list.body.items.filter(
      (item: any) => item.category === 'BOARD_SKIN' && item.equipped,
    );
    expect(equipped).toHaveLength(1);
    expect(equipped[0].key).toBe('board_classic');

    const repeat = await post(user, '/cosmetics/board_classic/equip');
    expect(repeat.status).toBe(200);
    expect(repeat.body.item.equipped).toBe(true);
  });

  it('refuses to equip an unowned cosmetic', async () => {
    const user = await registerUser(app);
    const res = await post(user, '/cosmetics/board_midnight/equip');
    expect(res.status).toBe(403);
    expect(JSON.stringify(res.body)).toContain('do not own');
  });

  it('purchases a premium cosmetic with coins and records the ledger entry', async () => {
    const user = await registerUser(app);
    const before = await wallet.getBalance(user.id);
    expect(before.balance).toBe(1000);

    const res = await post(user, '/cosmetics/board_midnight/purchase');
    expect(res.status).toBe(200);
    expect(res.body.item.owned).toBe(true);
    expect(res.body.item.source).toBe('purchase');
    expect(res.body.balance).toBe(750);

    const tx = await prisma().walletTransaction.findFirst({
      where: {
        walletId: before.id,
        type: 'COSMETIC_PURCHASE',
        refType: 'cosmetic',
        refId: 'board_midnight',
      },
    });
    expect(tx).not.toBeNull();
    expect(tx!.amount).toBe(-250);
    expect(tx!.balanceAfter).toBe(750);
    expect(tx!.idempotencyKey).toBe(`cosmetic:${user.id}:board_midnight`);

    const equip = await post(user, '/cosmetics/board_midnight/equip');
    expect(equip.status).toBe(200);

    const claim = await post(user, '/cosmetics/board_midnight/claim');
    expect(claim.status).toBe(409);
    const repurchase = await post(user, '/cosmetics/board_midnight/purchase');
    expect(repurchase.status).toBe(409);
  });

  it('reports insufficient balance without touching the wallet', async () => {
    const user = await registerUser(app);
    const walletRow = await wallet.getBalance(user.id);
    await prisma().wallet.update({
      where: { id: walletRow.id },
      data: { balance: 100 },
    });

    const res = await post(user, '/cosmetics/board_midnight/purchase');
    expect(res.status).toBe(400);
    expect(JSON.stringify(res.body)).toContain('Not enough coins.');

    const tx = await prisma().walletTransaction.findFirst({
      where: { walletId: walletRow.id, type: 'COSMETIC_PURCHASE' },
    });
    expect(tx).toBeNull();
  });

  it('grants cosmetics idempotently in development mode', async () => {
    const user = await registerUser(app);

    const grant = await post(user, '/cosmetics/victory_fireworks/grant');
    expect(grant.status).toBe(200);
    expect(grant.body.item.owned).toBe(true);
    expect(grant.body.item.source).toBe('dev_grant');

    const repeat = await post(user, '/cosmetics/victory_fireworks/grant');
    expect(repeat.status).toBe(200);
    expect(repeat.body.item.source).toBe('dev_grant');

    const purchase = await post(user, '/cosmetics/victory_fireworks/purchase');
    expect(purchase.status).toBe(409);
  });

  it('404s on unknown cosmetic keys', async () => {
    const user = await registerUser(app);
    expect((await post(user, '/cosmetics/no_such_item/claim')).status).toBe(404);
    expect((await post(user, '/cosmetics/no_such_item/equip')).status).toBe(404);
    expect((await post(user, '/cosmetics/no_such_item/purchase')).status).toBe(404);
    expect((await post(user, '/cosmetics/no_such_item/grant')).status).toBe(404);
  });

  it('requires authentication for the whole surface', async () => {
    const base = `${apiPrefix(app)}/cosmetics`;
    expect((await request(app.getHttpServer()).get(base)).status).toBe(401);
    expect(
      (await request(app.getHttpServer()).post(`${base}/board_classic/claim`)).status,
    ).toBe(401);
    expect(
      (await request(app.getHttpServer()).post(`${base}/board_classic/grant`)).status,
    ).toBe(401);
  });

  it('rejects malformed cosmetic keys with 400', async () => {
    const user = await registerUser(app);
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/cosmetics/BAD%20KEY/claim`)
      .set(auth(user.accessToken))
      .send({});
    expect(res.status).toBe(400);
  });
});
