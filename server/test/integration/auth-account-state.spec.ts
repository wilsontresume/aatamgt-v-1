import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma, registerUser } from '../helpers/fixtures';

/**
 * Security regression: an access token is a *claim*, never the truth.
 * Account state (status, role, deletion) must be re-read from the
 * database on every authenticated request, so bans, demotions and
 * deletions take effect immediately instead of surviving inside an
 * unexpired token until its TTL runs out.
 */
describe('Account state vs. access tokens (security regression)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await app.close();
    await closePrisma();
  });

  it('rejects a banned account even with an unexpired access token', async () => {
    const victim = await registerUser(app);

    const before = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/auth/session`)
      .set(auth(victim.accessToken));
    expect(before.status).toBe(200);

    await prisma().user.update({ where: { id: victim.id }, data: { status: 'BANNED' } });

    const session = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/auth/session`)
      .set(auth(victim.accessToken));
    expect(session.status).toBe(401);

    const wallet = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/wallet`)
      .set(auth(victim.accessToken));
    expect(wallet.status).toBe(401);

    const refresh = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/refresh`)
      .send({ refreshToken: victim.refreshToken });
    expect(refresh.status).toBe(401);

    await prisma().user.update({ where: { id: victim.id }, data: { status: 'ACTIVE' } });
  });

  it('rejects a suspended account even with an unexpired access token', async () => {
    const victim = await registerUser(app);
    await prisma().user.update({ where: { id: victim.id }, data: { status: 'SUSPENDED' } });

    const session = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/auth/session`)
      .set(auth(victim.accessToken));
    expect(session.status).toBe(401);

    await prisma().user.update({ where: { id: victim.id }, data: { status: 'ACTIVE' } });
  });

  it('serves the role from the database, not from the token', async () => {
    const user = await registerUser(app); // token minted with role USER

    const asUser = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/stats`)
      .set(auth(user.accessToken));
    expect(asUser.status).toBe(403);

    // Promotion is visible to the already-issued token.
    await prisma().user.update({ where: { id: user.id }, data: { role: 'ADMIN' } });
    const promoted = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/stats`)
      .set(auth(user.accessToken));
    expect(promoted.status).toBe(200);

    // Demotion must strip admin rights from the same token immediately —
    // this was the confirmed vulnerability: the token kept saying ADMIN.
    await prisma().user.update({ where: { id: user.id }, data: { role: 'USER' } });
    const demoted = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/admin/stats`)
      .set(auth(user.accessToken));
    expect(demoted.status).toBe(403);
  });

  it('rejects a soft-deleted account', async () => {
    const victim = await registerUser(app);
    await prisma().user.update({ where: { id: victim.id }, data: { deletedAt: new Date() } });

    const session = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/auth/session`)
      .set(auth(victim.accessToken));
    expect(session.status).toBe(401);
  });
});
