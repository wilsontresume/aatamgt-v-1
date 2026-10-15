import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import {
  apiPrefix,
  auth,
  closePrisma,
  createGameFixture,
  prisma,
  registerUser,
} from '../helpers/fixtures';

describe('Matches (integration)', () => {
  let app: INestApplication;
  let alice: Awaited<ReturnType<typeof registerUser>>;
  let bob: Awaited<ReturnType<typeof registerUser>>;
  let carol: Awaited<ReturnType<typeof registerUser>>;
  let gameKey: string;
  let matchId: string;

  beforeAll(async () => {
    app = await createTestApp();
    [alice, bob, carol] = await Promise.all([
      registerUser(app),
      registerUser(app),
      registerUser(app),
    ]);
    gameKey = await createGameFixture();
  });

  afterAll(async () => {
    await app.close();
    await closePrisma();
  });

  it('creates a pending match with the creator seated', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken))
      .send({ gameKey });
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('PENDING');
    expect(res.body.players).toHaveLength(1);
    expect(res.body.players[0]).toMatchObject({ userId: alice.id, seat: 0, result: 'PENDING' });
    matchId = res.body.id;
  });

  it('rejects client-supplied stakes on the public create endpoint', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken))
      .send({ gameKey, stakeCoins: 100 });
    // Public REST never accepts stakes — matchmaking is the only path.
    expect(res.status).toBe(403);
  });

  it('activates the match when the second player joins', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/join`)
      .set(auth(bob.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ACTIVE');
    expect(res.body.players).toHaveLength(2);
  });

  it('rejects moves from players outside the match', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/moves`)
      .set(auth(carol.accessToken))
      .send({ payload: { action: 'cheat' } });
    expect(res.status).toBe(403);
  });

  it('assigns sequence numbers server-side and stores the move log', async () => {
    const first = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/moves`)
      .set(auth(alice.accessToken))
      .send({ payload: { action: 'move', to: 'a3' } });
    expect(first.status).toBe(200);
    expect(first.body.move.seq).toBe(1);
    expect(first.body.stateVersion).toBeGreaterThanOrEqual(1);

    const outOfOrder = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/moves`)
      .set(auth(bob.accessToken))
      .send({ payload: { action: 'move', to: 'b4' }, clientSeq: 1 });
    expect(outOfOrder.status).toBe(409);

    const second = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/moves`)
      .set(auth(bob.accessToken))
      .send({ payload: { action: 'move', to: 'b4' }, clientSeq: 2 });
    expect(second.status).toBe(200);
    expect(second.body.move.seq).toBe(2);
  });

  it('returns the match with its move history and no invented result', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches/${matchId}`)
      .set(auth(alice.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.moves).toHaveLength(2);
    expect(res.body.players.every((p: { result: string }) => p.result === 'PENDING')).toBe(true);
    expect(res.body.completedAt).toBeNull();
  });

  it('hides the match from non-participants (horizontal read regression)', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches/${matchId}`)
      .set(auth(carol.accessToken));
    expect(res.status).toBe(403);
    expect(res.body.moves).toBeUndefined();
  });

  it('rejects malformed history limits instead of crashing', async () => {
    const notANumber = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches/${matchId}?history=abc`)
      .set(auth(alice.accessToken));
    expect(notANumber.status).toBe(400);

    const negative = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches/${matchId}?history=-5`)
      .set(auth(alice.accessToken));
    expect(negative.status).toBe(400);

    const tooLarge = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches/${matchId}?history=500`)
      .set(auth(alice.accessToken));
    expect(tooLarge.status).toBe(400);
  });

  it('records a loss for the player who leaves an active match', async () => {
    const bobProfileBefore = await prisma().profile.findUnique({ where: { userId: bob.id } });
    expect(bobProfileBefore).not.toBeNull();

    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/leave`)
      .set(auth(bob.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('COMPLETED');

    const results: Record<string, string> = Object.fromEntries(
      res.body.players.map((p: { userId: string; result: string }) => [p.userId, p.result]),
    );
    expect(results[bob.id]).toBe('LOSS');
    expect(results[alice.id]).toBe('WIN');

    // The dodge regression: before the fix the leaver's record and rating
    // were left untouched, so a losing player could quit to avoid a loss.
    const bobProfileAfter = await prisma().profile.findUnique({ where: { userId: bob.id } });
    expect(bobProfileAfter!.losses).toBe(bobProfileBefore!.losses + 1);
    expect(bobProfileAfter!.rating).toBeLessThan(bobProfileBefore!.rating);
    expect(bobProfileAfter!.gamesPlayed).toBe(bobProfileBefore!.gamesPlayed + 1);

    const move = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/moves`)
      .set(auth(alice.accessToken))
      .send({ payload: { action: 'move' } });
    expect(move.status).toBe(409);
  });

  it('lists my matches', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.items.length).toBeGreaterThanOrEqual(1);
  });
});
