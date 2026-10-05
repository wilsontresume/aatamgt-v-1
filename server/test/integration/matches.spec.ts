import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, createGameFixture, registerUser } from '../helpers/fixtures';

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

  it('refuses staked matches while gameplay is unimplemented', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken))
      .send({ gameKey, stakeCoins: 100 });
    expect(res.status).toBe(409);
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

  it('abandons the match when a participant leaves', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/leave`)
      .set(auth(bob.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ABANDONED');
    expect(
      res.body.players.every((p: { userId: string; result: string }) =>
        p.userId === bob.id ? p.result === 'ABANDONED' : p.result === 'PENDING',
      ),
    ).toBe(true);

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
