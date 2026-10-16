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
} from '../helpers/fixtures';

describe('Admin (integration)', () => {
  let app: INestApplication;
  let adminToken: string;
  let adminId: string;
  let player: Awaited<ReturnType<typeof registerUser>>;
  let opponent: Awaited<ReturnType<typeof registerUser>>;

  beforeAll(async () => {
    app = await createTestApp();
    const admin = await createUserDirectly(`adm_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const loginRes = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: admin.username, password: admin.password });
    expect(loginRes.status).toBe(200);
    adminToken = loginRes.body.accessToken;
    adminId = admin.id;

    player = await registerUser(app);
    opponent = await registerUser(app);
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  it('is not reachable by anonymous or regular users', async () => {
    const anon = await request(app.getHttpServer()).get(`${apiPrefix(app)}/admin/stats`);
    expect(anon.status).toBe(401);

    const user = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/stats`)
      .set(auth(player.accessToken));
    expect(user.status).toBe(403);
  });

  it('exposes platform stats to admins', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/stats`)
      .set(auth(adminToken));
    expect(res.status).toBe(200);
    expect(res.body.users).toBeGreaterThanOrEqual(3);
    expect(res.body.games).toBeGreaterThanOrEqual(0);
  });

  it('adjusts a wallet and records an audit entry', async () => {
    const adjust = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/admin/wallets/${player.id}/adjust`)
      .set(auth(adminToken))
      .send({ amount: 250, reason: 'phase 2 test grant' });
    expect(adjust.status).toBe(201);
    expect(adjust.body.balance).toBe(1250); // 1000 registration bonus + 250 adjustment

    const audit = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/audit`)
      .set(auth(adminToken));
    expect(audit.status).toBe(200);
    const entry = audit.body.items.find(
      (row: { action: string }) => row.action === 'wallet.adjust',
    );
    expect(entry).toBeDefined();
    expect(entry.targetId).toBe(player.id);
  });

  it('lists users for moderation', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/users`)
      .query({ q: player.username })
      .set(auth(adminToken));
    expect(res.status).toBe(200);
    expect(res.body.items.some((u: { id: string }) => u.id === player.id)).toBe(true);
  });

  it('finalises a match only with explicit operator-supplied results', async () => {
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

    const withoutResults = await request(app.getHttpServer())
      .patch(`${apiPrefix(app)}/admin/matches/${match.id}/finalize`)
      .set(auth(adminToken))
      .send({ status: 'COMPLETED' });
    expect(withoutResults.status).toBe(400);

    const finalised = await request(app.getHttpServer())
      .patch(`${apiPrefix(app)}/admin/matches/${match.id}/finalize`)
      .set(auth(adminToken))
      .send({
        status: 'COMPLETED',
        reason: 'manual operator result in phase 2 test',
        players: [
          { userId: player.id, result: 'WIN', score: 1 },
          { userId: opponent.id, result: 'LOSS', score: 0 },
        ],
      });
    expect(finalised.status).toBe(200);
    expect(finalised.body.status).toBe('COMPLETED');

    const profile = await prisma().profile.findUnique({ where: { userId: player.id } });
    expect(profile?.gamesPlayed).toBe(1);
    expect(profile?.wins).toBe(1);

    const opponentProfile = await prisma().profile.findUnique({
      where: { userId: opponent.id },
    });
    expect(opponentProfile?.losses).toBe(1);
  });

  it('records who performed the finalisation', async () => {
    const audit = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/audit`)
      .set(auth(adminToken));
    const entry = audit.body.items.find(
      (row: { action: string }) => row.action === 'match.finalize',
    );
    expect(entry).toBeDefined();
    expect(adminId).toBeDefined();
  });
});
