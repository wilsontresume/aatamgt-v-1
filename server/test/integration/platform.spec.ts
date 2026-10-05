import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  createUserDirectly,
  prisma,
  registerUser,
} from '../helpers/fixtures';

describe('Platform modules (integration)', () => {
  let app: INestApplication;
  let alice: Awaited<ReturnType<typeof registerUser>>;
  let bob: Awaited<ReturnType<typeof registerUser>>;
  let adminToken: string;

  beforeAll(async () => {
    app = await createTestApp();
    alice = await registerUser(app);
    bob = await registerUser(app);
    const admin = await createUserDirectly(`adm_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const login = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: admin.username, password: admin.password });
    adminToken = login.body.accessToken;
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  describe('games catalog', () => {
    it('exposes active games publicly and rejects unknown keys', async () => {
      const list = await request(app.getHttpServer()).get(`${apiPrefix(app)}/games`);
      expect(list.status).toBe(200);
      expect(Array.isArray(list.body.items)).toBe(true);

      const missing = await request(app.getHttpServer()).get(
        `${apiPrefix(app)}/games/does-not-exist`,
      );
      expect(missing.status).toBe(404);
    });

    it('lets admins register a new game title', async () => {
      const key = `game-${uniqueSuffix()}`;
      const created = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/games`)
        .set(auth(adminToken))
        .send({ key, name: 'Chaturanga', slug: key, minPlayers: 2, maxPlayers: 4 });
      expect(created.status).toBe(201);
      expect(created.body.key).toBe(key);

      const forbidden = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/games`)
        .set(auth(alice.accessToken))
        .send({ key: `${key}-x`, name: 'Nope', slug: `${key}-x` });
      expect(forbidden.status).toBe(403);
    });
  });

  describe('profiles', () => {
    it('updates the caller profile and reflects it publicly', async () => {
      const updated = await request(app.getHttpServer())
        .patch(`${apiPrefix(app)}/profiles/me`)
        .set(auth(alice.accessToken))
        .send({ displayName: 'Alice A', countryCode: 'IN', bio: 'strategy player' });
      expect(updated.status).toBe(200);
      expect(updated.body.displayName).toBe('Alice A');
      expect(updated.body.countryCode).toBe('IN');

      const publicView = await request(app.getHttpServer()).get(
        `${apiPrefix(app)}/profiles/${alice.username}`,
      );
      expect(publicView.status).toBe(200);
      expect(publicView.body.displayName).toBe('Alice A');
      expect(publicView.body.stats).toMatchObject({ gamesPlayed: 0, wins: 0 });
    });

    it('hides private profiles behind a 404', async () => {
      await request(app.getHttpServer())
        .patch(`${apiPrefix(app)}/profiles/me`)
        .set(auth(bob.accessToken))
        .send({ isPublic: false });

      const res = await request(app.getHttpServer()).get(
        `${apiPrefix(app)}/profiles/${bob.username}`,
      );
      expect(res.status).toBe(404);

      await request(app.getHttpServer())
        .patch(`${apiPrefix(app)}/profiles/me`)
        .set(auth(bob.accessToken))
        .send({ isPublic: true });
    });

    it('validates profile payloads', async () => {
      const res = await request(app.getHttpServer())
        .patch(`${apiPrefix(app)}/profiles/me`)
        .set(auth(alice.accessToken))
        .send({ countryCode: 'india' });
      expect(res.status).toBe(400);
    });
  });

  describe('friends', () => {
    it('runs the full request → accept → list lifecycle', async () => {
      const request1 = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/requests`)
        .set(auth(alice.accessToken))
        .send({ username: bob.username });
      expect(request1.status).toBe(200);
      const friendshipId = request1.body.id;

      const duplicate = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/requests`)
        .set(auth(alice.accessToken))
        .send({ username: bob.username });
      expect(duplicate.status).toBe(409);

      const incoming = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/friends`)
        .set(auth(bob.accessToken));
      expect(incoming.body.incoming).toHaveLength(1);

      const accepted = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/requests/${friendshipId}/accept`)
        .set(auth(bob.accessToken));
      expect(accepted.status).toBe(200);
      expect(accepted.body.status).toBe('ACCEPTED');

      const list = await request(app.getHttpServer())
        .get(`${apiPrefix(app)}/friends`)
        .set(auth(alice.accessToken));
      expect(list.body.friends).toHaveLength(1);
      expect(list.body.friends[0].user.username).toBe(bob.username);
    });

    it('blocks a user and stops them from re-requesting', async () => {
      const carol = await registerUser(app);
      const block = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/block`)
        .set(auth(carol.accessToken))
        .send({ username: bob.username });
      expect(block.status).toBe(200);
      expect(block.body.status).toBe('BLOCKED');

      const retry = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/requests`)
        .set(auth(bob.accessToken))
        .send({ username: carol.username });
      expect(retry.status).toBe(403);
    });

    it('prevents self-friendship', async () => {
      const res = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/friends/requests`)
        .set(auth(alice.accessToken))
        .send({ username: alice.username });
      expect(res.status).toBe(400);
    });
  });

  describe('leaderboards', () => {
    it('materialises rankings from profile ratings and serves them', async () => {
      const refresh = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/leaderboards/global/refresh`)
        .set(auth(alice.accessToken));
      expect(refresh.status).toBe(201);
      expect(refresh.body.entries).toBeGreaterThanOrEqual(2);

      const board = await request(app.getHttpServer()).get(
        `${apiPrefix(app)}/leaderboards/global`,
      );
      expect(board.status).toBe(200);
      expect(board.body.items.length).toBeGreaterThanOrEqual(2);
      expect(board.body.items[0].rank).toBe(1);
      const scores = board.body.items.map((row: { score: number }) => row.score);
      expect([...scores].sort((a: number, b: number) => b - a)).toEqual(scores);
    });

    it('only counts completed wins for game-specific boards', async () => {
      const key = `game-${uniqueSuffix()}`;
      const game = await prisma().game.create({
        data: { key, name: 'Board', slug: key },
      });
      const match = await prisma().gameMatch.create({
        data: {
          gameId: game.id,
          gameKey: key,
          status: 'COMPLETED',
          completedAt: new Date(),
          createdByUserId: alice.id,
          players: {
            create: [
              { userId: alice.id, seat: 0, result: 'WIN' },
              { userId: bob.id, seat: 1, result: 'LOSS' },
            ],
          },
        },
      });
      expect(match.id).toBeDefined();

      const refresh = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/leaderboards/${key}/refresh`)
        .set(auth(alice.accessToken));
      expect(refresh.status).toBe(201);

      const board = await request(app.getHttpServer()).get(
        `${apiPrefix(app)}/leaderboards/${key}`,
      );
      expect(board.body.items).toHaveLength(1);
      expect(board.body.items[0]).toMatchObject({ userId: alice.id, score: 1, rank: 1 });
    });
  });
});
