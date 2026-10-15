import { INestApplication } from '@nestjs/common';
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

// Unique per run: the test database persists, so a fixed id would
// accumulate events across runs and break the count assertions. Must
// stay inside the hex installId pattern the endpoint enforces.
const RUN_SUFFIX = Date.now().toString(16) + Math.floor(Math.random() * 0xfffffff).toString(16);
const INSTALL_ID = `a1b2c3d4-e5f6-4a7b-8c9d-${RUN_SUFFIX}`.slice(0, 36).padEnd(36, '0');

describe('Analytics (integration)', () => {
  let app: INestApplication;

  beforeAll(async () => {
    app = await createTestApp();
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
  });

  // -------------------------------------------------------------------------
  // Acquisition: anonymous install / first-launch reporting (no account).
  // -------------------------------------------------------------------------

  it('accepts an anonymous install + first_launch batch keyed by installId', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/anonymous`)
      .send({
        installId: INSTALL_ID,
        platform: 'linux',
        version: '0.1.0',
        events: [
          { type: 'install', dedupeKey: `install:${INSTALL_ID}` },
          { type: 'first_launch', dedupeKey: `first_launch:${INSTALL_ID}` },
          { type: 'session_start', sessionId: 's-1' },
        ],
      });
    expect(res.status).toBe(201);
    expect(res.body).toEqual({ accepted: 3 });

    const events = await prisma().analyticsEvent.findMany({
      where: { installId: INSTALL_ID },
    });
    expect(events.map((e) => e.type).sort()).toEqual([
      'first_launch',
      'install',
      'session_start',
    ]);
    expect(events.every((e) => e.userId === null)).toBe(true);
  });

  it('replays of a dedupeKey do not duplicate the event', async () => {
    const before = await prisma().analyticsEvent.count({
      where: { installId: INSTALL_ID, type: 'install' },
    });
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/anonymous`)
      .send({
        installId: INSTALL_ID,
        events: [{ type: 'install', dedupeKey: `install:${INSTALL_ID}` }],
      });
    expect(res.status).toBe(201);
    const after = await prisma().analyticsEvent.count({
      where: { installId: INSTALL_ID, type: 'install' },
    });
    expect(after).toBe(before);
  });

  it('rejects an anonymous batch without an installId', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/anonymous`)
      .send({ events: [{ type: 'install' }] });
    expect(res.status).toBe(400);
  });

  it('rejects a malformed installId', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/anonymous`)
      .send({ installId: 'not a uuid!!', events: [{ type: 'install' }] });
    expect(res.status).toBe(400);
  });

  // -------------------------------------------------------------------------
  // Engagement: signed-in batches are attributed to the token's user.
  // -------------------------------------------------------------------------

  it('attributes an authenticated batch to the token user, never the body', async () => {
    const user = await registerUser(app);
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/events`)
      .set(auth(user.accessToken))
      .send({
        events: [
          { type: 'game_selected', gameKey: 'aadu-puli-aattam', sessionId: 's-2' },
          { type: 'ai_match_completed', gameKey: 'aadu-puli-aattam', data: { result: 'win' } },
          { type: 'share', data: { channel: 'whatsapp' } },
        ],
      });
    expect(res.status).toBe(201);
    expect(res.body).toEqual({ accepted: 3 });

    const events = await prisma().analyticsEvent.findMany({
      where: { userId: user.id },
      orderBy: { createdAt: 'asc' },
    });
    const types = events.map((e) => e.type);
    expect(types).toContain('game_selected');
    expect(types).toContain('ai_match_completed');
    expect(types).toContain('share');
    expect(events.every((e) => e.userId === user.id)).toBe(true);
  });

  it('rejects unauthenticated access to the authenticated endpoint', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/events`)
      .send({ events: [{ type: 'session_start' }] });
    expect(res.status).toBe(401);
  });

  // -------------------------------------------------------------------------
  // Anti-spoofing: server-authoritative types are rejected from clients.
  // -------------------------------------------------------------------------

  it('rejects server-authoritative event types submitted by a client', async () => {
    const user = await registerUser(app);
    for (const type of [
      'registration',
      'match_completed',
      'coin_purchase',
      'royal_pass_purchase',
      'cosmetic_purchase',
      'rewarded_ad_completed',
      'interstitial_displayed',
    ]) {
      const res = await request(app.getHttpServer())
        .post(`${apiPrefix(app)}/analytics/events`)
        .set(auth(user.accessToken))
        .send({ events: [{ type }] });
      expect(res.status).toBe(400);
    }
  });

  it('rejects an unknown event type on the anonymous endpoint', async () => {
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/anonymous`)
      .send({ installId: INSTALL_ID, events: [{ type: 'coin_purchase' }] });
    expect(res.status).toBe(400);
  });

  it('caps the batch size', async () => {
    const user = await registerUser(app);
    const events = Array.from({ length: 21 }, () => ({ type: 'session_start' }));
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/analytics/events`)
      .set(auth(user.accessToken))
      .send({ events });
    expect(res.status).toBe(400);
  });

  // -------------------------------------------------------------------------
  // Server-authoritative hooks: registration writes an event automatically.
  // -------------------------------------------------------------------------

  it('records a registration event automatically on account creation', async () => {
    const user = await registerUser(app);
    let event = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      event = await prisma().analyticsEvent.findFirst({
        where: { type: 'registration', userId: user.id },
      });
      if (event) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(event).not.toBeNull();
    expect(event?.dedupeKey).toBe(`registration:${user.id}`);
  });

  it('records friend_request and challenge events through their flows', async () => {
    const user = await registerUser(app);
    const target = await registerUser(app);

    const friendRes = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/friends/requests`)
      .set(auth(user.accessToken))
      .send({ username: target.username });
    expect([200, 201]).toContain(friendRes.status);

    const challengeRes = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/challenges`)
      .set(auth(user.accessToken))
      .send({ gameKey: 'aadu-puli-aattam' });
    expect([200, 201]).toContain(challengeRes.status);

    // Fire-and-forget writes: poll briefly for the events to land.
    let friendEvent = null;
    let challengeEvent = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      friendEvent ??= await prisma().analyticsEvent.findFirst({
        where: { type: 'friend_request', userId: user.id },
      });
      challengeEvent ??= await prisma().analyticsEvent.findFirst({
        where: { type: 'challenge_created', userId: user.id },
      });
      if (friendEvent && challengeEvent) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(friendEvent).not.toBeNull();
    expect(challengeEvent).not.toBeNull();
    expect(challengeEvent?.gameKey).toBe('aadu-puli-aattam');
  });

  it('records a match_completed event with result and reason for each player', async () => {
    const user = await registerUser(app);
    const opponent = await registerUser(app);

    const created = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(user.accessToken))
      .send({ gameKey: 'aadu-puli-aattam' });
    expect(created.status).toBe(201);
    const matchId = created.body.id;

    const joined = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/join`)
      .set(auth(opponent.accessToken));
    expect(joined.status).toBe(200);

    const resigned = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/matches/${matchId}/resign`)
      .set(auth(user.accessToken));
    expect(resigned.status).toBe(200);

    // Fire-and-forget writes: poll briefly for the events to land.
    let events: Array<{ userId: string | null; data: unknown }> = [];
    for (let attempt = 0; attempt < 20; attempt++) {
      events = await prisma().analyticsEvent.findMany({
        where: { type: 'match_completed', userId: { in: [user.id, opponent.id] } },
      });
      if (events.length >= 2) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(events.length).toBeGreaterThanOrEqual(2);
    const userEvent = events.find((e) => e.userId === user.id);
    const data = userEvent?.data as { result?: string; reason?: string } | null;
    expect(data?.result).toBe('LOSS');
    expect(data?.reason).toBe('RESIGN');

    const firstMatch = await prisma().analyticsEvent.findFirst({
      where: { type: 'first_match', userId: user.id },
    });
    expect(firstMatch).not.toBeNull();
  });

  // -------------------------------------------------------------------------
  // Monetization: ad + purchase hooks fire on their server flows.
  // -------------------------------------------------------------------------

  it('records rewarded ad lifecycle events on the server flows', async () => {
    const user = await registerUser(app);

    const session = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/ads/rewarded/session`)
      .set(auth(user.accessToken))
      .send({ tier: 'STANDARD' });
    expect(session.status).toBe(200);

    const redeem = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/ads/rewarded/redeem`)
      .set(auth(user.accessToken))
      .send({ nonce: session.body.nonce });
    expect(redeem.status).toBe(200);

    let started = null;
    let completed = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      started = await prisma().analyticsEvent.findFirst({
        where: { type: 'rewarded_ad_started', userId: user.id },
      });
      completed = await prisma().analyticsEvent.findFirst({
        where: { type: 'rewarded_ad_completed', userId: user.id },
      });
      if (started && completed) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(started).not.toBeNull();
    expect(completed).not.toBeNull();
    expect(completed?.dedupeKey).toMatch(/^rewarded_ad_completed:/);
  });

  it('records interstitial_displayed on the shown endpoint', async () => {
    const user = await registerUser(app);
    const res = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/ads/interstitial/shown`)
      .set(auth(user.accessToken))
      .send({});
    expect(res.status).toBe(200);

    let event = null;
    for (let attempt = 0; attempt < 20; attempt++) {
      event = await prisma().analyticsEvent.findFirst({
        where: { type: 'interstitial_displayed', userId: user.id },
      });
      if (event) break;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    expect(event).not.toBeNull();
  });

  // -------------------------------------------------------------------------
  // Summary: admin-only, with the expected metric sections.
  // -------------------------------------------------------------------------

  it('is admin-only', async () => {
    const user = await registerUser(app);
    const query = { from: '2026-01-01', to: '2026-01-02' };
    const anon = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/analytics/summary`)
      .query(query);
    expect(anon.status).toBe(401);
    const player = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/analytics/summary`)
      .set(auth(user.accessToken))
      .query(query);
    expect(player.status).toBe(403);
  });

  it('returns every metric section to an admin', async () => {
    const adminUser = await createUserDirectly(`adm_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const login = await request(app.getHttpServer())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: adminUser.username, password: adminUser.password });
    expect(login.status).toBe(200);

    const today = new Date().toISOString().slice(0, 10);
    const res = await request(app.getHttpServer())
      .get(`${apiPrefix(app)}/analytics/summary`)
      .set(auth(login.body.accessToken))
      .query({ from: today, to: today });
    expect(res.status).toBe(200);
    for (const section of [
      'acquisition',
      'engagement',
      'retention',
      'game',
      'social',
      'monetization',
      'totals',
    ]) {
      expect(res.body).toHaveProperty(section);
    }
    expect(res.body.retention).toHaveProperty('d1');
    expect(res.body.retention).toHaveProperty('d30');
    expect(Array.isArray(res.body.engagement.dauSeries)).toBe(true);
    expect(res.body.acquisition.install).toBeGreaterThanOrEqual(1);
    expect(res.body.monetization.rewardedCompleted).toBeGreaterThanOrEqual(1);
  });
});
