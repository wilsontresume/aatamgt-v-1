import type { INestApplication } from '@nestjs/common';
import request from 'supertest';

// Config is read from env when the Nest module boots in beforeAll, so the
// OAuth ids must exist before createTestApp() runs.
process.env.GOOGLE_CLIENT_ID = 'test-google-client-id';
process.env.FACEBOOK_APP_ID = 'test-fb-app-id';
process.env.FACEBOOK_APP_SECRET = 'test-fb-app-secret';

import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma } from '../helpers/fixtures';

interface SocialResponse {
  user: { id: string; username: string; email: string | null; isGuest: boolean };
  accessToken: string;
  refreshToken: string;
  upgraded: boolean;
}

// The integration database persists between runs, so every subject/email
// used here is run-scoped: a fresh identity each time, never a collision
// with a previous suite's rows.
const run = Date.now().toString(36);
const subject = (n: number) => `google-sub-${run}-${n}`;
const email = (name: string) => `${name}.${run}@example.com`;

type FetchRoute = {
  match: (url: string) => boolean;
  body: unknown;
  status?: number;
};

/** Mocks global fetch so provider verification never leaves the process. */
function mockProvider(routes: FetchRoute[]) {
  return jest.spyOn(global, 'fetch').mockImplementation(async (input) => {
    const url = String(input);
    const route = routes.find((r) => r.match(url));
    if (!route) {
      return { ok: false, status: 404, json: async () => ({}) } as Response;
    }
    return {
      ok: true,
      status: route.status ?? 200,
      json: async () => route.body,
    } as Response;
  });
}

function googleToken(token: string, over: Partial<Record<string, string>> = {}): FetchRoute[] {
  return [
    {
      match: (url) => url.startsWith('https://oauth2.googleapis.com/tokeninfo'),
      body: {
        aud: 'test-google-client-id',
        sub: subject(1),
        email: email('social.user'),
        email_verified: 'true',
        name: 'Social User',
        ...over,
      },
    },
  ];
}

describe('Social login (Google / Facebook) integration', () => {
  let app: INestApplication;
  let api: string;

  beforeAll(async () => {
    app = await createTestApp();
    api = apiPrefix(app);
  });

  afterAll(async () => {
    jest.restoreAllMocks();
    await app.close();
    await closePrisma();
  });

  it('creates a registered account from a verified Google token (with bonus)', async () => {
    mockProvider(googleToken('google-id-token-1'));

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'google', token: 'google-id-token-1' });

    expect(res.status).toBe(200);
    const body = res.body as SocialResponse;
    expect(body.user.isGuest).toBe(false);
    expect(body.user.email).toBe(email('social.user'));
    expect(body.accessToken).toEqual(expect.any(String));
    expect(body.upgraded).toBe(false);

    const stored = await prisma().socialAccount.findFirst({
      where: { provider: 'google', subject: subject(1) },
    });
    expect(stored?.userId).toBe(body.user.id);

    const wallet = await request(app.getHttpServer())
      .get(`${api}/wallet`)
      .set(auth(body.accessToken));
    expect(wallet.body.balance).toBe(1000); // registration bonus
  });

  it('links the identity to the calling guest and upgrades it in place', async () => {
    mockProvider(
      googleToken('google-id-token-2', { sub: subject(2), email: email('upgraded.guest') }),
    );

    const guest = await request(app.getHttpServer()).post(`${api}/auth/guest`);
    expect(guest.status).toBe(201);
    const guestId = guest.body.user.id as string;

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .set(auth(guest.body.accessToken))
      .send({ provider: 'google', token: 'google-id-token-2' });

    expect(res.status).toBe(200);
    const body = res.body as SocialResponse;
    expect(body.user.id).toBe(guestId); // same account, progress kept
    expect(body.user.isGuest).toBe(false);
    expect(body.upgraded).toBe(true);

    const conversion = await prisma().analyticsEvent.findFirst({
      where: { type: 'guest_conversion', userId: guestId },
    });
    expect(conversion).not.toBeNull();

    const wallet = await request(app.getHttpServer())
      .get(`${api}/wallet`)
      .set(auth(body.accessToken));
    expect(wallet.body.balance).toBe(1000); // guest bonus survived the upgrade
  });

  it('re-login with the same Google identity returns the linked account', async () => {
    mockProvider(
      googleToken('google-id-token-3', { sub: subject(1), email: email('social.user') }),
    );

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'google', token: 'google-id-token-3' });

    expect(res.status).toBe(200);
    const body = res.body as SocialResponse;
    expect(body.user.email).toBe(email('social.user'));
    expect(body.user.isGuest).toBe(false);
    expect(body.upgraded).toBe(false);

    const count = await prisma().socialAccount.count({
      where: { provider: 'google', subject: subject(1) },
    });
    expect(count).toBe(1);
  });

  it('rejects a Google token minted for a different audience', async () => {
    mockProvider(googleToken('google-id-token-x', { aud: 'someone-elses-client-id' }));

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'google', token: 'google-id-token-x' });

    expect(res.status).toBe(401);
  });

  it('verifies Facebook tokens via debug_token + /me', async () => {
    mockProvider([
      {
        match: (url) => url.startsWith('https://graph.facebook.com/debug_token'),
        body: { data: { is_valid: true, app_id: 'test-fb-app-id', user_id: `fb-user-${run}` } },
      },
      {
        match: (url) => url.startsWith('https://graph.facebook.com/me'),
        body: {
          id: `fb-user-${run}`,
          name: 'FB Player',
          email: email('fb.player'),
        },
      },
    ]);

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'facebook', token: 'fb-user-token-1' });

    expect(res.status).toBe(200);
    const body = res.body as SocialResponse;
    expect(body.user.isGuest).toBe(false);
    expect(body.user.email).toBe(email('fb.player'));

    const stored = await prisma().socialAccount.findFirst({
      where: { provider: 'facebook', subject: `fb-user-${run}` },
    });
    expect(stored?.userId).toBe(body.user.id);
  });

  it('rejects an invalid Facebook token (is_valid: false)', async () => {
    mockProvider([
      {
        match: (url) => url.startsWith('https://graph.facebook.com/debug_token'),
        body: { data: { is_valid: false, app_id: 'test-fb-app-id', user_id: `fb-bad-${run}` } },
      },
    ]);

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'facebook', token: 'bad-fb-token' });

    expect(res.status).toBe(401);
  });

  it('refuses to steal an already-linked identity into another guest', async () => {
    mockProvider(
      googleToken('google-id-token-4', { sub: subject(1), email: email('social.user') }),
    );

    const otherGuest = await request(app.getHttpServer()).post(`${api}/auth/guest`);

    const res = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .set(auth(otherGuest.body.accessToken))
      .send({ provider: 'google', token: 'google-id-token-4' });

    expect(res.status).toBe(409);

    const still = await prisma().user.findUnique({
      where: { id: otherGuest.body.user.id },
    });
    expect(still?.isGuest).toBe(true); // guest untouched by the failed link
  });

  it('rejects unknown providers and missing tokens via validation', async () => {
    const badProvider = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'twitter', token: 'x'.repeat(20) });
    expect(badProvider.status).toBe(400);

    const missingToken = await request(app.getHttpServer())
      .post(`${api}/auth/social`)
      .send({ provider: 'google' });
    expect(missingToken.status).toBe(400);
  });
});
