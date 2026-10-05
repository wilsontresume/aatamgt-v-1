import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, registerUser } from '../helpers/fixtures';

describe('Wallet & daily rewards (integration)', () => {
  let app: INestApplication;
  let token: string;
  let userId: string;

  beforeAll(async () => {
    app = await createTestApp();
    const user = await registerUser(app);
    token = user.accessToken;
    userId = user.id;
  });

  afterAll(async () => {
    await app.close();
  });

  it('starts with an empty coin wallet', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(token));
    expect(res.status).toBe(200);
    expect(res.body.balance).toBe(0);
    expect(res.body.currency).toBe('COIN');
  });

  it('claims the daily reward exactly once per day', async () => {
    const first = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/rewards/daily/claim`)
      .set(auth(token));
    expect(first.status).toBe(200);
    expect(first.body.coins).toBe(50);
    expect(first.body.streakDay).toBe(1);
    expect(first.body.balance).toBe(50);

    const second = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/rewards/daily/claim`)
      .set(auth(token));
    expect(second.status).toBe(409);
  });

  it('reports claim status and ledger entries', async () => {
    const status = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/rewards/daily`)
      .set(auth(token));
    expect(status.status).toBe(200);
    expect(status.body.todayClaimed).toBe(true);

    const balance = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(token));
    expect(balance.body.balance).toBe(50);

    const txs = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet/transactions`)
      .set(auth(token));
    expect(txs.status).toBe(200);
    expect(txs.body.total).toBe(1);
    expect(txs.body.items[0].type).toBe('DAILY_REWARD');
    expect(txs.body.items[0].balanceAfter).toBe(50);
  });

  it('creates a notification for the claimed reward', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/notifications`)
      .set(auth(token));
    expect(res.status).toBe(200);
    expect(res.body.items.some((n: { type: string }) => n.type === 'daily_reward')).toBe(true);

    const count = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/notifications/unread-count`)
      .set(auth(token));
    expect(count.body.count).toBeGreaterThanOrEqual(1);

    const readAll = await request(app.getHttpServer())
      .patch(`${apiPrefix(app)}/notifications/read-all`)
      .set(auth(token));
    expect(readAll.body.updated).toBeGreaterThanOrEqual(1);
  });

  it('requires authentication for wallet access', async () => {
    const res = await request(app.getHttpServer()).get(`${apiPrefix(app)}/wallet`);
    expect(res.status).toBe(401);
    expect(userId).toBeDefined();
  });
});
