import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth } from '../helpers/fixtures';

interface GuestResponse {
  user: { id: string; username: string; isGuest: boolean };
  accessToken: string;
  refreshToken: string;
}

describe('Guest login (integration)', () => {
  let app: INestApplication;
  let rawGuestBody: string;
  let guest1: GuestResponse;
  let guest2: GuestResponse;

  beforeAll(async () => {
    app = await createTestApp();
    const first = await request(app.getHttpServer()).post(`${apiPrefix(app)}/auth/guest`);
    rawGuestBody = JSON.stringify(first.body);
    guest1 = first.body as GuestResponse;
    const second = await request(app.getHttpServer()).post(`${apiPrefix(app)}/auth/guest`);
    guest2 = second.body as GuestResponse;
  });

  afterAll(async () => {
    await app.close();
  });

  it('creates a guest account and returns session tokens', () => {
    expect(guest1.user.isGuest).toBe(true);
    expect(guest1.user.username).toMatch(/^guest_[a-f0-9]{8}$/);
    expect(guest1.accessToken).toEqual(expect.any(String));
    expect(guest1.refreshToken).toEqual(expect.any(String));
  });

  it('never returns password material of any kind', () => {
    expect(rawGuestBody).not.toContain('password');
    expect(rawGuestBody).not.toContain('passwordHash');
  });

  it('issues a distinct identity per guest sign-in', () => {
    expect(guest1.user.id).not.toBe(guest2.user.id);
    expect(guest1.user.username).not.toBe(guest2.user.username);
  });

  it('lets a guest use its access token on protected routes', async () => {
    const me = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/users/me`)
      .set(auth(guest1.accessToken));
    expect(me.status).toBe(200);
    expect(me.body.id).toBe(guest1.user.id);

    const profile = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/profiles/me`)
      .set(auth(guest1.accessToken));
    expect(profile.status).toBe(200);
    expect(profile.body.username).toBe(guest1.user.username);
  });

  it('rotates guest refresh tokens like any other session', async () => {
    const refreshed = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: guest2.refreshToken });
    expect(refreshed.status).toBe(200);

    const reused = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: guest2.refreshToken });
    expect(reused.status).toBe(401);
  });

  it('rejects invalid credentials on the password login route', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: guest1.user.username, password: 'guessed-password' });
    expect(res.status).toBe(401);
    expect(res.body.message).toMatch(/invalid credentials/i);
  });

  it('grants every new guest the registration bonus (free credits)', async () => {
    const balance = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(guest1.accessToken));
    expect(balance.status).toBe(200);
    expect(balance.body.balance).toBe(1000); // coins.registration_bonus default

    const txs = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet/transactions`)
      .set(auth(guest2.accessToken));
    expect(txs.status).toBe(200);
    const bonuses = txs.body.items.filter(
      (tx: { type: string }) => tx.type === 'REGISTRATION_BONUS',
    );
    expect(bonuses).toHaveLength(1);
    expect(bonuses[0].amount).toBe(1000);
    expect(bonuses[0].memo).toMatch(/guest/i);
  });
});
