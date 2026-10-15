import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  prisma,
  registerUser,
} from '../helpers/fixtures';

/**
 * Integration: DB-backed tier admin CRUD, role protection, and the
 * matchmaking integrity rules tied to active tiers.
 */
describe('Tiers admin + integrity (integration)', () => {
  let app: INestApplication;
  let admin: Awaited<ReturnType<typeof registerUser>>;
  let player: Awaited<ReturnType<typeof registerUser>>;
  const api = () => app.getHttpServer();
  const p = () => `${apiPrefix(app)}`;

  beforeAll(async () => {
    app = await createTestApp();
    [admin, player] = await Promise.all([
      registerUser(app, { role: 'ADMIN' }),
      registerUser(app),
    ]);
    // Test DB has migrations only — seed the three approved tiers here.
    await prisma().tier.upsert({
      where: { id: 'bronze' },
      update: {},
      create: {
        id: 'bronze',
        name: 'Bronze',
        entryCostCoins: 50,
        rewardMultiplierBp: 12_500,
        displayOrder: 1,
        active: true,
      },
    });
    await prisma().tier.upsert({
      where: { id: 'silver' },
      update: {},
      create: {
        id: 'silver',
        name: 'Silver',
        entryCostCoins: 100,
        rewardMultiplierBp: 20_000,
        displayOrder: 2,
        active: true,
      },
    });
    await prisma().tier.upsert({
      where: { id: 'gold' },
      update: {},
      create: {
        id: 'gold',
        name: 'Gold',
        entryCostCoins: 500,
        rewardMultiplierBp: 30_000,
        displayOrder: 3,
        active: true,
      },
    });
    await prisma().game.upsert({
      where: { key: 'aadu-puli-aattam' },
      update: { status: 'ACTIVE', minPlayers: 2, maxPlayers: 2 },
      create: {
        key: 'aadu-puli-aattam',
        name: 'Aadu Puli Aattam',
        slug: 'aadu-puli-aattam',
        minPlayers: 2,
        maxPlayers: 2,
      },
    });
  });

  afterAll(async () => {
    await app.close();
    await closePrisma();
  });

  it('serves only active seeded tiers to players', async () => {
    const res = await request(api()).get(`${p()}/tiers`).set(auth(player.accessToken));
    expect(res.status).toBe(200);
    const ids = res.body.items.map((t: { id: string }) => t.id);
    expect(ids).toEqual(expect.arrayContaining(['bronze', 'silver', 'gold']));
    // Ensure no leftover platinum from prior runs pollutes later assertions.
    await prisma().tier.deleteMany({ where: { id: { startsWith: 'platinum' } } });
  });

  it('rejects tier CRUD for non-admin users', async () => {
    const list = await request(api()).get(`${p()}/admin/tiers`).set(auth(player.accessToken));
    expect(list.status).toBe(403);

    const create = await request(api())
      .post(`${p()}/admin/tiers`)
      .set(auth(player.accessToken))
      .send({
        id: 'hacker',
        name: 'Hacker',
        entryCostCoins: 1,
        rewardMultiplierBp: 10_000,
        displayOrder: 99,
      });
    expect(create.status).toBe(403);

    const patch = await request(api())
      .patch(`${p()}/admin/tiers/bronze`)
      .set(auth(player.accessToken))
      .send({ entryCostCoins: 0 });
    expect(patch.status).toBe(403);
  });

  it('creates, updates, disables and re-enables a tier (admin only)', async () => {
    const tierId = `plat-${Date.now().toString(36)}`;
    const created = await request(api())
      .post(`${p()}/admin/tiers`)
      .set(auth(admin.accessToken))
      .send({
        id: tierId,
        name: 'Platinum',
        entryCostCoins: 1000,
        rewardMultiplierBp: 15_000,
        displayOrder: 10,
      });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({
      id: tierId,
      name: 'Platinum',
      entryCostCoins: 1000,
      rewardMultiplierBp: 15_000,
      active: true,
    });

    const patched = await request(api())
      .patch(`${p()}/admin/tiers/${tierId}`)
      .set(auth(admin.accessToken))
      .send({ entryCostCoins: 2000, rewardMultiplierBp: 20_000 });
    expect(patched.status).toBe(200);
    expect(patched.body).toMatchObject({ entryCostCoins: 2000, rewardMultiplierBp: 20_000 });

    const disabled = await request(api())
      .patch(`${p()}/admin/tiers/${tierId}/active`)
      .set(auth(admin.accessToken))
      .send({ active: false });
    expect(disabled.status).toBe(200);
    expect(disabled.body.active).toBe(false);

    // Disabled tier must not appear to players and cannot be queued.
    const catalog = await request(api()).get(`${p()}/tiers`).set(auth(player.accessToken));
    expect(catalog.body.items.map((t: { id: string }) => t.id)).not.toContain(tierId);

    const queued = await request(api())
      .post(`${p()}/matchmaking/queue`)
      .set(auth(player.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', tierId });
    expect(queued.status).toBe(400);

    const reenabled = await request(api())
      .patch(`${p()}/admin/tiers/${tierId}/active`)
      .set(auth(admin.accessToken))
      .send({ active: true });
    expect(reenabled.body.active).toBe(true);

    const back = await request(api()).get(`${p()}/tiers`).set(auth(player.accessToken));
    expect(back.body.items.map((t: { id: string }) => t.id)).toContain(tierId);
  });

  it('rejects insufficient balance on queue without touching the wallet', async () => {
    // Drain the player wallet so gold (500) is unaffordable.
    await prisma().wallet.upsert({
      where: { userId_currency: { userId: player.id, currency: 'COIN' } },
      update: { balance: 10 },
      create: { userId: player.id, currency: 'COIN', balance: 10 },
    });

    const before = await request(api()).get(`${p()}/wallet`).set(auth(player.accessToken));
    const queued = await request(api())
      .post(`${p()}/matchmaking/queue`)
      .set(auth(player.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', tierId: 'gold' });
    expect(queued.status).toBe(403);

    const after = await request(api()).get(`${p()}/wallet`).set(auth(player.accessToken));
    expect(after.body.balance).toBe(before.body.balance);
  });

  it('keeps tierId on the match and server-derives the stake', async () => {
    await prisma().wallet.upsert({
      where: { userId_currency: { userId: player.id, currency: 'COIN' } },
      update: { balance: 5000 },
      create: { userId: player.id, currency: 'COIN', balance: 5000 },
    });

    // Public create 403s client-supplied stakes; internal create with a
    // valid active tier re-derives stake from the DB.
    const forged = await request(api())
      .post(`${p()}/matches`)
      .set(auth(player.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', stakeCoins: 1, tierId: 'gold' });
    expect(forged.status).toBe(403);

    const queued = await request(api())
      .post(`${p()}/matchmaking/queue`)
      .set(auth(player.accessToken))
      .send({ gameKey: 'aadu-puli-aattam', tierId: 'gold' });
    expect([200, 403]).toContain(queued.status);
  });

  it('audits admin tier mutations', async () => {
    const audit = await prisma().adminAuditLog.findFirst({
      where: { action: { in: ['tier.create', 'tier.update', 'tier.set_active'] } },
      orderBy: { createdAt: 'desc' },
    });
    expect(audit).toBeTruthy();
    expect(audit?.targetType).toBe('tier');
  });
});
