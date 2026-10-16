import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';

jest.setTimeout(40_000);

describe('Phase C — user & account management', () => {
  let app: INestApplication;
  let api: string;
  let admin: TestUser; // the suite's only active admin during the lock tests
  let adminB: TestUser; // second admin, created when the guard must be lifted
  let mod: TestUser;
  let player: TestUser;
  let guestId: string;
  let suspendedId: string;
  /** Roles of pre-existing active admins, demoted during the last-admin tests and restored afterwards. */
  let stashedAdmins: { id: string }[] = [];

  const auth = (token: string) => ({ Authorization: `Bearer ${token}` });

  beforeAll(async () => {
    app = await createTestApp();
    api = apiPrefix(app);
    admin = await registerUser(app, { role: 'ADMIN', username: `pc_${uniqueSuffix()}`.slice(0, 24) });
    adminB = await registerUser(app, { username: `pc_${uniqueSuffix()}`.slice(0, 24) });
    mod = await registerUser(app, { role: 'MODERATOR', username: `pc_${uniqueSuffix()}`.slice(0, 24) });
    player = await registerUser(app, { username: `pc_${uniqueSuffix()}`.slice(0, 24) });

    const guestRes = await request(app.getHttpServer()).post(`${api}/auth/guest`);
    guestId = guestRes.body.user.id;

    // A suspended target for the status filter, created through the real API.
    const victim = await registerUser(app, { username: `pc_${uniqueSuffix()}`.slice(0, 24) });
    suspendedId = victim.id;
    const suspended = await request(app.getHttpServer())
      .patch(`${api}/admin/users/${suspendedId}/status`)
      .set(auth(admin.accessToken))
      .send({ status: 'SUSPENDED', reason: 'phase-c fixture' });
    expect(suspended.status).toBe(200);
  });

  afterAll(async () => {
    for (const row of stashedAdmins) {
      await prisma().user.update({ where: { id: row.id }, data: { role: 'ADMIN' } });
    }
    stashedAdmins = [];
    // Defensive: leave this suite's fixtures in a sane state for later suites
    // even if a mid-suite assertion failed during the role-lock tests.
    await prisma().user.updateMany({
      where: { id: { in: [admin.id, adminB.id] } },
      data: { role: 'ADMIN', status: 'ACTIVE' },
    });
    // Audit-neutral: remove rows this suite created so the shared test DB's
    // audit table does not grow every run (admin-dashboard.spec reads a
    // fixed-size latest-audit window).
    const suiteActorIds = [admin.id, adminB.id, mod.id];
    await prisma().adminAuditLog.deleteMany({ where: { actorUserId: { in: suiteActorIds } } });
    await prisma().moderationNote.deleteMany({
      where: { targetUserId: { in: [player.id, adminB.id] } },
    });
    await app.close();
    await closePrisma();
  });

  describe('user listing', () => {
    it('is denied to USER and anonymous callers', async () => {
      expect((await request(app.getHttpServer()).get(`${api}/admin/users`)).status).toBe(401);
      expect(
        (await request(app.getHttpServer()).get(`${api}/admin/users`).set(auth(player.accessToken)))
          .status,
      ).toBe(403);
    });

    it('is readable by MODERATOR with win/loss stats and no secrets', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ q: player.username })
        .set(auth(mod.accessToken));
      expect(res.status).toBe(200);
      const row = res.body.items.find((u: { id: string }) => u.id === player.id);
      expect(row).toBeDefined();
      expect(row.isGuest).toBe(false);
      expect(row.stats).toMatchObject({
        wins: expect.any(Number),
        losses: expect.any(Number),
        draws: expect.any(Number),
        gamesPlayed: expect.any(Number),
        rating: expect.any(Number),
        level: expect.any(Number),
      });
      const raw = JSON.stringify(res.body);
      expect(raw).not.toContain('passwordHash');
      expect(raw).not.toContain('tokenHash');
      expect(raw).not.toContain('refreshToken');
    });

    it('finds a user by exact player id', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ q: player.id })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.items).toHaveLength(1);
      expect(res.body.items[0].id).toBe(player.id);
    });

    it('filters by account type', async () => {
      const guests = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ accountType: 'guest', limit: 100 })
        .set(auth(admin.accessToken));
      expect(guests.status).toBe(200);
      expect(guests.body.items.length).toBeGreaterThan(0);
      expect(guests.body.items.every((u: { isGuest: boolean }) => u.isGuest)).toBe(true);
      expect(guests.body.items.some((u: { id: string }) => u.id === guestId)).toBe(true);

      const registered = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ accountType: 'registered', limit: 100 })
        .set(auth(admin.accessToken));
      expect(registered.body.items.every((u: { isGuest: boolean }) => !u.isGuest)).toBe(true);
      expect(registered.body.items.some((u: { id: string }) => u.id === guestId)).toBe(false);
    });

    it('filters by account status', async () => {
      const suspended = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ status: 'SUSPENDED', limit: 100 })
        .set(auth(admin.accessToken));
      expect(suspended.status).toBe(200);
      expect(suspended.body.items.every((u: { status: string }) => u.status === 'SUSPENDED')).toBe(true);
      expect(suspended.body.items.some((u: { id: string }) => u.id === suspendedId)).toBe(true);

      const active = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ status: 'ACTIVE', limit: 100 })
        .set(auth(admin.accessToken));
      expect(active.body.items.some((u: { id: string }) => u.id === suspendedId)).toBe(false);
    });

    it('paginates', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ limit: 1, page: 2 })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.page).toBe(2);
      expect(res.body.limit).toBe(1);
      expect(res.body.items).toHaveLength(1);
      expect(res.body.total).toBeGreaterThanOrEqual(2);
    });

    it('rejects an invalid account type', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .query({ accountType: 'bot' })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(400);
    });
  });

  describe('moderation notes', () => {
    it('creates a note with author and timestamp, and audits it', async () => {
      const res = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/notes`)
        .set(auth(mod.accessToken))
        .send({ body: '  Checked for griefing behaviour.  ' });
      expect(res.status).toBe(201);
      expect(res.body.body).toBe('Checked for griefing behaviour.');
      expect(res.body.author.username).toBe(mod.username);
      expect(typeof res.body.createdAt).toBe('string');

      const list = await request(app.getHttpServer())
        .get(`${api}/admin/users/${player.id}/notes`)
        .set(auth(mod.accessToken));
      expect(list.status).toBe(200);
      expect(list.body.total).toBeGreaterThanOrEqual(1);
      expect(list.body.items[0].author.username).toBe(mod.username);

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ action: 'moderation.note.create' })
        .set(auth(admin.accessToken));
      expect(audit.status).toBe(200);
      const entry = audit.body.items.find((r: { targetId: string }) => r.targetId === player.id);
      expect(entry).toBeDefined();
      expect(entry.actor).toBe(mod.username);
    });

    it('validates the note body', async () => {
      const blank = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/notes`)
        .set(auth(admin.accessToken))
        .send({ body: '   ' });
      expect(blank.status).toBe(400);

      const missing = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/notes`)
        .set(auth(admin.accessToken))
        .send({});
      expect(missing.status).toBe(400);

      const tooLong = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/notes`)
        .set(auth(admin.accessToken))
        .send({ body: 'x'.repeat(1001) });
      expect(tooLong.status).toBe(400);
    });

    it('is forbidden for USER and 404s for unknown users', async () => {
      const forbidden = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/notes`)
        .set(auth(player.accessToken))
        .send({ body: 'self note' });
      expect(forbidden.status).toBe(403);

      const missing = await request(app.getHttpServer())
        .get(`${api}/admin/users/does-not-exist/notes`)
        .set(auth(admin.accessToken));
      expect(missing.status).toBe(404);
    });
  });

  describe('session revocation', () => {
    it('revokes every refresh token and blocks further refreshes', async () => {
      const second = await request(app.getHttpServer())
        .post(`${api}/auth/login`)
        .send({ identifier: player.username, password: player.password });
      expect(second.status).toBe(200);
      const tokenA = player.refreshToken;
      const tokenB = second.body.refreshToken;

      const res = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/revoke-sessions`)
        .set(auth(admin.accessToken));
      expect(res.status).toBe(201);
      expect(res.body.sessionsRevoked).toBeGreaterThanOrEqual(2);

      for (const token of [tokenA, tokenB]) {
        const refresh = await request(app.getHttpServer())
          .post(`${api}/auth/refresh`)
          .send({ refreshToken: token });
        expect(refresh.status).toBe(401);
      }

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ action: 'user.sessions.revoke', actor: admin.username })
        .set(auth(admin.accessToken));
      expect(audit.status).toBe(200);
      const entry = audit.body.items.find((r: { targetId: string }) => r.targetId === player.id);
      expect(entry).toBeDefined();
      expect(entry.data.sessionsRevoked).toBeGreaterThanOrEqual(2);
    });

    it('is ADMIN-only', async () => {
      const res = await request(app.getHttpServer())
        .post(`${api}/admin/users/${player.id}/revoke-sessions`)
        .set(auth(mod.accessToken));
      expect(res.status).toBe(403);
    });

    it('404s for unknown users', async () => {
      const res = await request(app.getHttpServer())
        .post(`${api}/admin/users/does-not-exist/revoke-sessions`)
        .set(auth(admin.accessToken));
      expect(res.status).toBe(404);
    });
  });

  describe('role management', () => {
    it('promotes with an audit entry and revokes stale sessions', async () => {
      const before = await request(app.getHttpServer())
        .post(`${api}/auth/login`)
        .send({ identifier: adminB.username, password: adminB.password });
      const staleRefresh = before.body.refreshToken;

      const res = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${adminB.id}/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'MODERATOR' });
      expect(res.status).toBe(200);
      expect(res.body.role).toBe('MODERATOR');
      expect(res.body.sessionsRevoked).toBeGreaterThanOrEqual(1);

      const refresh = await request(app.getHttpServer())
        .post(`${api}/auth/refresh`)
        .send({ refreshToken: staleRefresh });
      expect(refresh.status).toBe(401);

      const audit = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ action: 'user.role' })
        .set(auth(admin.accessToken));
      const entry = audit.body.items.find((r: { targetId: string }) => r.targetId === adminB.id);
      expect(entry).toBeDefined();
      expect(entry.data).toMatchObject({ previous: 'USER', next: 'MODERATOR' });

      // The new role is live immediately (JWT strategy reads the DB).
      // Note: await the login BEFORE constructing the dependent request —
      // interleaving a nested awaited request inside another Test's argument
      // chain lets supertest close the shared test server mid-dispatch.
      const adminBLogin = await login(adminB);
      const asMod = await request(app.getHttpServer())
        .get(`${api}/admin/users`)
        .set(auth(adminBLogin.accessToken));
      expect(asMod.status).toBe(200);
    });

    it('is denied to MODERATOR and USER', async () => {
      const byMod = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${player.id}/role`)
        .set(auth(mod.accessToken))
        .send({ role: 'MODERATOR' });
      expect(byMod.status).toBe(403);

      const byUser = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${mod.id}/role`)
        .set(auth(player.accessToken))
        .send({ role: 'USER' });
      expect(byUser.status).toBe(403);
    });

    it('validates the role value and user existence', async () => {
      const bad = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${player.id}/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'SUPERADMIN' });
      expect(bad.status).toBe(400);

      const missing = await request(app.getHttpServer())
        .patch(`${api}/admin/users/does-not-exist/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'USER' });
      expect(missing.status).toBe(404);
    });

    it('blocks demoting the last active administrator (including self)', async () => {
      // Reduce the platform to exactly one active admin: this suite's `admin`.
      const others = await prisma().user.findMany({
        where: { role: 'ADMIN', status: 'ACTIVE', deletedAt: null, id: { not: admin.id } },
        select: { id: true },
      });
      stashedAdmins = others;
      for (const row of others) {
        await prisma().user.update({ where: { id: row.id }, data: { role: 'MODERATOR' } });
      }

      const selfDemote = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${admin.id}/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'USER' });
      expect(selfDemote.status).toBe(409);
      expect(selfDemote.body.message).toMatch(/last active administrator/i);

      const stillAdmin = await prisma().user.findUniqueOrThrow({
        where: { id: admin.id },
        select: { role: true },
      });
      expect(stillAdmin.role).toBe('ADMIN');
    });

    it('allows self-demotion once a second administrator exists', async () => {
      const promote = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${adminB.id}/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'ADMIN' });
      expect(promote.status).toBe(200);

      const selfDemote = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${admin.id}/role`)
        .set(auth(admin.accessToken))
        .send({ role: 'USER' });
      expect(selfDemote.status).toBe(200);
      expect(selfDemote.body.role).toBe('USER');

      // Restore this suite's admin (adminB now holds the last active admin).
      const adminBLogin = await login(adminB);
      const restore = await request(app.getHttpServer())
        .patch(`${api}/admin/users/${admin.id}/role`)
        .set(auth(adminBLogin.accessToken))
        .send({ role: 'ADMIN' });
      expect(restore.status).toBe(200);
    });
  });

  describe('audit log filters', () => {
    it('filters by action', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ action: 'user.role', limit: 100 })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.items.length).toBeGreaterThan(0);
      expect(res.body.items.every((r: { action: string }) => r.action === 'user.role')).toBe(true);
      expect(res.body.items[0]).toHaveProperty('data');
      expect(res.body.items[0]).toHaveProperty('actor');
    });

    it('filters by actor username', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ actor: mod.username, limit: 100 })
        .set(auth(admin.accessToken));
      expect(res.status).toBe(200);
      expect(res.body.items.length).toBeGreaterThan(0);
      expect(res.body.items.every((r: { actor: string }) => r.actor === mod.username)).toBe(true);
    });

    it('filters by date range with YYYY-MM-DD validation', async () => {
      const today = new Date().toISOString().slice(0, 10);
      const inRange = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ from: today, to: today, limit: 100 })
        .set(auth(admin.accessToken));
      expect(inRange.status).toBe(200);
      expect(inRange.body.items.length).toBeGreaterThan(0);
      expect(
        inRange.body.items.every((r: { createdAt: string }) => r.createdAt.slice(0, 10) === today),
      ).toBe(true);

      const tomorrow = new Date(Date.now() + 86_400_000).toISOString().slice(0, 10);
      const future = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ from: tomorrow, limit: 100 })
        .set(auth(admin.accessToken));
      expect(future.status).toBe(200);
      expect(future.body.items).toHaveLength(0);

      const bad = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .query({ from: '16-10-2026' })
        .set(auth(admin.accessToken));
      expect(bad.status).toBe(400);
    });

    it('stays ADMIN-only', async () => {
      const res = await request(app.getHttpServer())
        .get(`${api}/admin/audit`)
        .set(auth(mod.accessToken));
      expect(res.status).toBe(403);
    });
  });

  async function login(user: TestUser): Promise<{ accessToken: string; refreshToken: string }> {
    const res = await request(app.getHttpServer())
      .post(`${api}/auth/login`)
      .send({ identifier: user.username, password: user.password });
    expect(res.status).toBe(200);
    return res.body;
  }
});
