import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, login } from '../helpers/fixtures';

describe('Auth (integration)', () => {
  let app: INestApplication;
  let username: string;
  let password: string;
  let tokens: { accessToken: string; refreshToken: string };

  beforeAll(async () => {
    app = await createTestApp();
    username = `auth_${uniqueSuffix()}`.slice(0, 24);
    password = 'Sup3rSecret!';
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/register`)
      .send({ username, password, email: `${username}@example.com` });
    expect(res.status).toBe(201);
    tokens = { accessToken: res.body.accessToken, refreshToken: res.body.refreshToken };
  });

  afterAll(async () => {
    await app.close();
  });

  it('registers a user without leaking the password hash', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/register`)
      .send({ username: `auth_${uniqueSuffix()}`.slice(0, 24), password: 'Sup3rSecret!' });
    expect(res.status).toBe(201);
    expect(res.body.user.passwordHash).toBeUndefined();
    expect(res.body.user.username).toBeDefined();
    expect(res.body.accessToken).toEqual(expect.any(String));
    expect(res.body.refreshToken).toEqual(expect.any(String));
  });

  it('rejects duplicate usernames with 409', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/register`)
      .send({ username, password });
    expect(res.status).toBe(409);
    expect(res.body.message).toMatch(/taken/i);
  });

  it('rejects malformed payloads with 400', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/register`)
      .send({ username: 'x', password: 'short' });
    expect(res.status).toBe(400);
  });

  it('logs in with valid credentials and rejects invalid ones', async () => {
    const ok = await login(app, username, password);
    expect(ok.status).toBe(200);

    const bad = await login(app, username, 'wrong-password');
    expect(bad.status).toBe(401);
  });

  it('serves the current user only with a valid access token', async () => {
    const without = await request(app.getHttpServer()).get(`${apiPrefix(app)}/users/me`);
    expect(without.status).toBe(401);

    const withToken = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/users/me`)
      .set('Authorization', `Bearer ${tokens.accessToken}`);
    expect(withToken.status).toBe(200);
    expect(withToken.body.username).toBe(username);
    expect(withToken.body.passwordHash).toBeUndefined();
  });

  it('rotates refresh tokens and rejects reuse of the old one', async () => {
    const first = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: tokens.refreshToken });
    expect(first.status).toBe(200);
    expect(first.body.refreshToken).not.toBe(tokens.refreshToken);

    const reuse = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: tokens.refreshToken });
    expect(reuse.status).toBe(401);

    tokens = { accessToken: first.body.accessToken, refreshToken: first.body.refreshToken };

    const reuseNew = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: tokens.refreshToken });
    expect(reuseNew.status).toBe(200);
    tokens = { accessToken: reuseNew.body.accessToken, refreshToken: reuseNew.body.refreshToken };
  });

  it('rejects tampered access tokens', async () => {
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/users/me`)
      .set('Authorization', 'Bearer not.a.real.token');
    expect(res.status).toBe(401);
  });
});

describe('Auth rate limiting (integration)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
  });

  it('returns 429 once the login throttle limit is exceeded', async () => {
    // The effective limit comes from AUTH_THROTTLE_LIMIT (setup-env.ts).
    const limit = Number(process.env.AUTH_THROTTLE_LIMIT ?? 10);
    const statuses: number[] = [];
    for (let i = 0; i < limit + 3; i++) {
      const res = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/auth/login`)
        .send({ identifier: 'nobody', password: 'whatever' });
      statuses.push(res.status);
    }
    expect(statuses.slice(0, limit)).toEqual(Array(limit).fill(401));
    expect(statuses[limit]).toBe(429);
    expect(statuses[limit + 1]).toBe(429);
    expect(statuses[limit + 2]).toBe(429);
  });

  it('keeps other endpoints available while throttled', async () => {
    const res = await request(app.getHttpServer()).get('/health');
    expect(res.status).toBe(200);
  });
});
