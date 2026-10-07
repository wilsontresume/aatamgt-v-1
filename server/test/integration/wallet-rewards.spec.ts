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

  it('starts with the configured registration bonus in the ledger', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(token));
    expect(res.status).toBe(200);
    expect(res.body.balance).toBe(1000);
    expect(res.body.currency).toBe('COIN');

    const txs = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet/transactions`)
      .set(auth(token));
    expect(txs.body.total).toBe(1);
    expect(txs.body.items[0].type).toBe('REGISTRATION_BONUS');
    expect(txs.body.items[0].amount).toBe(1000);
    expect(txs.body.items[0].balanceAfter).toBe(1000);
    expect(txs.body.items[0].refType).toBe('registration');
  });

  it('claims the daily reward exactly once per day', async () => {
    const first = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/rewards/daily/claim`)
      .set(auth(token));
    expect(first.status).toBe(200);
    expect(first.body.coins).toBe(100);
    expect(first.body.streakDay).toBe(1);
    expect(first.body.balance).toBe(1100);

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
    expect(status.body.nextRewardCoins).toBe(100);

    const balance = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(token));
    expect(balance.body.balance).toBe(1100);

    const txs = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet/transactions`)
      .set(auth(token));
    expect(txs.status).toBe(200);
    expect(txs.body.total).toBe(2);
    const daily = txs.body.items.find((row: { type: string }) => row.type === 'DAILY_LOGIN');
    expect(daily).toBeDefined();
    expect(daily.amount).toBe(100);
    expect(daily.balanceAfter).toBe(1100);
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
