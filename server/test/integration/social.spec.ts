import type { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, auth, closePrisma, prisma, registerUser, TestUser } from '../helpers/fixtures';

const GAME_KEY = 'aadu-puli-aattam';

// Social rate limits — read once at app boot (beforeAll), restored afterwards.
const PREV_FRIEND_PER_HOUR = process.env.FRIEND_REQUEST_PER_HOUR;
const PREV_FRIEND_PENDING = process.env.FRIEND_PENDING_LIMIT;
const PREV_CHALLENGE_PER_HOUR = process.env.CHALLENGE_CREATE_PER_HOUR;
const PREV_CHALLENGE_PENDING = process.env.CHALLENGE_PENDING_LIMIT;
const PREV_CHALLENGE_TTL = process.env.CHALLENGE_TTL_SECONDS;
const PREV_AUTH_LIMIT = process.env.AUTH_THROTTLE_LIMIT;
process.env.FRIEND_REQUEST_PER_HOUR = '5';
process.env.FRIEND_PENDING_LIMIT = '3';
process.env.CHALLENGE_CREATE_PER_HOUR = '5';
process.env.CHALLENGE_PENDING_LIMIT = '3';
process.env.CHALLENGE_TTL_SECONDS = '900';
// This suite registers dozens of one-off users; the default auth cap is 20/min.
process.env.AUTH_THROTTLE_LIMIT = '500';

describe('Social multiplayer (integration)', () => {
  let app: INestApplication;

  const post = (user: TestUser, path: string, body: Record<string, unknown> = {}) =>
    request(app.getHttpServer())
      .post(`${apiPrefix(app)}${path}`)
      .set(auth(user.accessToken))
      .send(body);

  const get = (user: TestUser, path: string) =>
    request(app.getHttpServer())
      .get(`${apiPrefix(app)}${path}`)
      .set(auth(user.accessToken));

  beforeAll(async () => {
    await prisma().game.upsert({
      where: { key: GAME_KEY },
      update: { status: 'ACTIVE', minPlayers: 2, maxPlayers: 2 },
      create: {
        key: GAME_KEY,
        name: 'Aadu Puli Aattam',
        slug: GAME_KEY,
        minPlayers: 2,
        maxPlayers: 2,
      },
    });
    app = await createTestApp();
  });

  afterAll(async () => {
    await closePrisma();
    await app.close();
    const restore = (key: string, value: string | undefined) => {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    };
    restore('FRIEND_REQUEST_PER_HOUR', PREV_FRIEND_PER_HOUR);
    restore('FRIEND_PENDING_LIMIT', PREV_FRIEND_PENDING);
    restore('CHALLENGE_CREATE_PER_HOUR', PREV_CHALLENGE_PER_HOUR);
    restore('CHALLENGE_PENDING_LIMIT', PREV_CHALLENGE_PENDING);
    restore('CHALLENGE_TTL_SECONDS', PREV_CHALLENGE_TTL);
    restore('AUTH_THROTTLE_LIMIT', PREV_AUTH_LIMIT);
  });

  // -------------------------------------------------------------------------
  // Friend requests
  // -------------------------------------------------------------------------

  describe('friend requests', () => {
    it('re-sends after a decline by resetting the row to PENDING', async () => {
      const u1 = await registerUser(app);
      const u2 = await registerUser(app);

      const first = await post(u1, '/friends/requests', { username: u2.username });
      expect(first.status).toBe(200);
      const decline = await post(u2, `/friends/requests/${first.body.id}/decline`);
      expect(decline.status).toBe(200);
      expect(decline.body.status).toBe('DECLINED');

      const resend = await post(u1, '/friends/requests', { username: u2.username });
      expect(resend.status).toBe(200);
      expect(resend.body.status).toBe('PENDING');
      expect(resend.body.id).toBe(first.body.id);

      const list = await get(u2, '/friends');
      expect(list.body.incoming).toHaveLength(1);
      expect(list.body.incoming[0].user.username).toBe(u1.username);
    });

    it('answers duplicates with distinct messages per direction', async () => {
      const u1 = await registerUser(app);
      const u2 = await registerUser(app);

      const send = await post(u1, '/friends/requests', { username: u2.username });
      expect(send.status).toBe(200);

      const sameSide = await post(u1, '/friends/requests', { username: u2.username });
      expect(sameSide.status).toBe(409);
      expect(sameSide.body.message).toBe('A friendship request already exists');

      const otherSide = await post(u2, '/friends/requests', { username: u1.username });
      expect(otherSide.status).toBe(409);
      expect(otherSide.body.message).toBe('They already sent you a request');

      await post(u2, `/friends/requests/${send.body.id}/accept`);
      const alreadyFriends = await post(u1, '/friends/requests', { username: u2.username });
      expect(alreadyFriends.status).toBe(409);
      expect(alreadyFriends.body.message).toBe('You are already friends');
    });

    it('removes a friendship and allows a fresh request', async () => {
      const u1 = await registerUser(app);
      const u2 = await registerUser(app);
      const send = await post(u1, '/friends/requests', { username: u2.username });
      await post(u2, `/friends/requests/${send.body.id}/accept`);

      const del = await request(app.getHttpServer())
        .delete(`${apiPrefix(app)}/friends/${send.body.id}`)
        .set(auth(u2.accessToken));
      expect(del.status).toBe(200);

      const after = await get(u1, '/friends');
      expect(after.body.friends).toHaveLength(0);

      const again = await post(u1, '/friends/requests', { username: u2.username });
      expect(again.status).toBe(200);
    });

    it('stops both directions while blocked and works again after unblock', async () => {
      const u1 = await registerUser(app);
      const u2 = await registerUser(app);
      const send = await post(u1, '/friends/requests', { username: u2.username });
      await post(u2, `/friends/requests/${send.body.id}/accept`);

      const block = await post(u2, '/friends/block', { username: u1.username });
      expect(block.status).toBe(200);
      expect(block.body.status).toBe('BLOCKED');

      const fromBlocked = await post(u1, '/friends/requests', { username: u2.username });
      expect(fromBlocked.status).toBe(403);

      const towardBlocker = await post(u2, '/friends/requests', { username: u1.username });
      expect(towardBlocker.status).toBe(403);

      const list = await get(u2, '/friends');
      expect(list.body.blocked).toHaveLength(1);
      expect(list.body.friends).toHaveLength(0);

      const unblock = await request(app.getHttpServer())
        .delete(`${apiPrefix(app)}/friends/${block.body.id}`)
        .set(auth(u2.accessToken));
      expect(unblock.status).toBe(200);

      const after = await post(u1, '/friends/requests', { username: u2.username });
      expect(after.status).toBe(200);
    });

    it('rate limits pending count first, then hourly volume', async () => {
      const spammer = await registerUser(app);
      const recipients: TestUser[] = [];
      for (let i = 0; i < 6; i++) recipients.push(await registerUser(app));

      // FRIEND_PENDING_LIMIT = 3: three sends pass, the fourth is capped.
      const firstThree = [0, 1, 2];
      for (const i of firstThree) {
        const res = await post(spammer, '/friends/requests', {
          username: recipients[i].username,
        });
        expect(res.status).toBe(200);
      }
      const pendingCapped = await post(spammer, '/friends/requests', {
        username: recipients[3].username,
      });
      expect(pendingCapped.status).toBe(429);
      expect(pendingCapped.body.message).toBe('Too many pending requests. Wait for a reply.');

      // Drain the pending cap, then hit the hourly volume limit (5 per hour).
      for (const i of firstThree) {
        const list = await get(recipients[i], '/friends');
        await post(recipients[i], `/friends/requests/${list.body.incoming[0].id}/accept`);
      }
      for (const i of [3, 4]) {
        const res = await post(spammer, '/friends/requests', {
          username: recipients[i].username,
        });
        expect(res.status).toBe(200);
      }
      const hourlyCapped = await post(spammer, '/friends/requests', {
        username: recipients[5].username,
      });
      expect(hourlyCapped.status).toBe(429);
      expect(hourlyCapped.body.message).toBe('Too many requests today. Try again later.');
    });

    it('notifies both sides of the handshake', async () => {
      const u1 = await registerUser(app);
      const u2 = await registerUser(app);
      const send = await post(u1, '/friends/requests', { username: u2.username });

      const u2Feed = await get(u2, '/notifications');
      const requestNote = (u2Feed.body.items as Array<Record<string, unknown>>).find(
        (n) => n.type === 'friend_request',
      );
      expect(requestNote).toBeDefined();
      expect(String(requestNote?.title)).toBe('Friend request');

      await post(u2, `/friends/requests/${send.body.id}/accept`);
      const u1Feed = await get(u1, '/notifications');
      const acceptNote = (u1Feed.body.items as Array<Record<string, unknown>>).find(
        (n) => n.type === 'friend_accepted',
      );
      expect(acceptNote).toBeDefined();
      expect(String(acceptNote?.title)).toBe('Friend request accepted');
    });
  });

  // -------------------------------------------------------------------------
  // Challenges
  // -------------------------------------------------------------------------

  describe('challenges', () => {
    const CODE_RE = /^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{8}$/;

    it('creates a shareable code for an invitee and notifies them', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);

      const res = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });
      expect(res.status).toBe(200);
      expect(res.body.code).toMatch(CODE_RE);
      expect(res.body.status).toBe('PENDING');
      expect(res.body.gameKey).toBe(GAME_KEY);
      expect(res.body.gameName).toBe('Aadu Puli Aattam');
      expect(res.body.challenger.username).toBe(challenger.username);
      expect(res.body.invitee.username).toBe(invitee.username);
      expect(res.body.matchId).toBeNull();
      expect(new Date(res.body.expiresAt).getTime()).toBeGreaterThan(Date.now());

      const feed = await get(invitee, '/notifications');
      const note = (feed.body.items as Array<Record<string, unknown>>).find(
        (n) => n.type === 'challenge',
      );
      expect(note).toBeDefined();
      expect(String(note?.body)).toContain(challenger.username);
      expect(String(note?.body)).toContain('Aadu Puli Aattam');
    });

    it('shows the code to both parties and hides it from strangers', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);
      const stranger = await registerUser(app);
      const created = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });

      const asInvitee = await get(invitee, `/challenges/${created.body.code}`);
      expect(asInvitee.status).toBe(200);
      const asChallenger = await get(challenger, `/challenges/${created.body.code}`);
      expect(asChallenger.status).toBe(200);
      const asStranger = await get(stranger, `/challenges/${created.body.code}`);
      expect(asStranger.status).toBe(404);

      const missing = await get(invitee, '/challenges/ZZZZZZZZ');
      expect(missing.status).toBe(404);
    });

    it('accepting starts an ACTIVE private match with the correct seats', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);
      const created = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });

      const accepted = await post(invitee, `/challenges/${created.body.code}/accept`);
      expect(accepted.status).toBe(200);
      expect(accepted.body.status).toBe('ACCEPTED');
      expect(accepted.body.matchId).toBeTruthy();
      expect(accepted.body.seat).toBe(1);

      const match = await get(invitee, `/matches/${accepted.body.matchId}`);
      expect(match.status).toBe(200);
      expect(match.body.status).toBe('ACTIVE');
      expect(match.body.mode).toBe('PRIVATE');
      expect(match.body.players).toHaveLength(2);
      const seats = new Map(
        (match.body.players as Array<Record<string, unknown>>).map((p) => [
          p.username,
          p.seat,
        ]),
      );
      expect(seats.get(challenger.username)).toBe(0);
      expect(seats.get(invitee.username)).toBe(1);

      const second = await post(invitee, `/challenges/${created.body.code}/accept`);
      expect(second.status).toBe(409);
      const self = await post(challenger, `/challenges/${created.body.code}/accept`);
      expect(self.status).toBe(400);
    });

    it('keeps an invitee-scoped code away from other accounts', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);
      const other = await registerUser(app);
      const created = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });

      const peek = await get(other, `/challenges/${created.body.code}`);
      expect(peek.status).toBe(404);
      const steal = await post(other, `/challenges/${created.body.code}/accept`);
      expect(steal.status).toBe(404);
    });

    it('declines and cancels pending challenges', async () => {
      const c1 = await registerUser(app);
      const i1 = await registerUser(app);
      const declined = await post(c1, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: i1.username,
      });
      const doDecline = await post(i1, `/challenges/${declined.body.code}/decline`);
      expect(doDecline.status).toBe(200);
      expect(doDecline.body.status).toBe('DECLINED');
      const lateAccept = await post(i1, `/challenges/${declined.body.code}/accept`);
      expect(lateAccept.status).toBe(409);

      const c2 = await registerUser(app);
      const i2 = await registerUser(app);
      const cancelled = await post(c2, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: i2.username,
      });
      const wrongCancel = await post(i2, `/challenges/${cancelled.body.code}/cancel`);
      expect(wrongCancel.status).toBe(403);
      const doCancel = await post(c2, `/challenges/${cancelled.body.code}/cancel`);
      expect(doCancel.status).toBe(200);
      expect(doCancel.body.status).toBe('CANCELLED');
      const inviteeTriesDecline = await post(i2, `/challenges/${cancelled.body.code}/decline`);
      expect(inviteeTriesDecline.status).toBe(409);

      const challengerDeclines = await post(c1, `/challenges/${declined.body.code}/decline`);
      expect(challengerDeclines.status).toBe(400);
    });

    it('expires overdue challenges lazily', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);
      const created = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });

      await prisma().challenge.update({
        where: { id: created.body.id },
        data: { expiresAt: new Date(Date.now() - 1000) },
      });

      const peek = await get(invitee, `/challenges/${created.body.code}`);
      expect(peek.status).toBe(200);
      expect(peek.body.status).toBe('EXPIRED');

      const late = await post(invitee, `/challenges/${created.body.code}/accept`);
      expect(late.status).toBe(409);
      expect(late.body.message).toBe('Challenge has expired');
    });

    it('supports open codes that any holder may accept', async () => {
      const challenger = await registerUser(app);
      const holder = await registerUser(app);
      const created = await post(challenger, '/challenges', { gameKey: GAME_KEY });
      expect(created.body.invitee).toBeNull();

      const peek = await get(holder, `/challenges/${created.body.code}`);
      expect(peek.status).toBe(200);

      const accepted = await post(holder, `/challenges/${created.body.code}/accept`);
      expect(accepted.status).toBe(200);
      expect(accepted.body.status).toBe('ACCEPTED');
      const match = await get(holder, `/matches/${accepted.body.matchId}`);
      expect(match.body.status).toBe('ACTIVE');
    });

    it('rate limits pending count first, then hourly volume', async () => {
      const spammer = await registerUser(app);
      const invitees: TestUser[] = [];
      for (let i = 0; i < 6; i++) invitees.push(await registerUser(app));

      const codes: string[] = [];
      for (let i = 0; i < 3; i++) {
        const res = await post(spammer, '/challenges', {
          gameKey: GAME_KEY,
          inviteeUsername: invitees[i].username,
        });
        expect(res.status).toBe(200);
        codes.push(res.body.code);
      }
      const pendingCapped = await post(spammer, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitees[3].username,
      });
      expect(pendingCapped.status).toBe(429);
      expect(pendingCapped.body.message).toBe('Too many pending challenges. Wait for a reply.');

      // Drain pending by having each own invitee accept (404s wouldn't drain).
      for (let i = 0; i < codes.length; i++) {
        const drained = await post(invitees[i], `/challenges/${codes[i]}/accept`);
        expect(drained.status).toBe(200);
      }

      for (const i of [3, 4]) {
        const res = await post(spammer, '/challenges', {
          gameKey: GAME_KEY,
          inviteeUsername: invitees[i].username,
        });
        expect(res.status).toBe(200);
      }
      const hourlyCapped = await post(spammer, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitees[5].username,
      });
      expect(hourlyCapped.status).toBe(429);
      expect(hourlyCapped.body.message).toBe('Too many challenges created. Try again later.');
    });

    it('refuses challenges across a block, both directions', async () => {
      const blocker = await registerUser(app);
      const target = await registerUser(app);

      const block = await post(blocker, '/friends/block', { username: target.username });
      expect(block.status).toBe(200);

      const towardBlocker = await post(target, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: blocker.username,
      });
      expect(towardBlocker.status).toBe(403);
      expect(towardBlocker.body.message).toBe('Cannot send to this player');
    });

    it('refuses a pending challenge once the invitee blocks the challenger', async () => {
      const challenger = await registerUser(app);
      const invitee = await registerUser(app);
      const created = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: invitee.username,
      });
      expect(created.status).toBe(200);

      const block = await post(invitee, '/friends/block', { username: challenger.username });
      expect(block.status).toBe(200);

      const accept = await post(invitee, `/challenges/${created.body.code}/accept`);
      expect(accept.status).toBe(404);
      const peek = await get(invitee, `/challenges/${created.body.code}`);
      expect(peek.status).toBe(404);
    });

    it('validates the invitee, the game, and self-challenge', async () => {
      const challenger = await registerUser(app);

      const self = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: challenger.username,
      });
      expect(self.status).toBe(400);

      const unknown = await post(challenger, '/challenges', {
        gameKey: GAME_KEY,
        inviteeUsername: 'nobody_here',
      });
      expect(unknown.status).toBe(404);

      const badGame = await post(challenger, '/challenges', { gameKey: 'missing-game-key' });
      expect(badGame.status).toBe(404);

      const party = await prisma().game.create({
        data: {
          key: `party-${uniqueSuffix()}`,
          name: 'Party Game',
          slug: `party-${uniqueSuffix()}`,
          minPlayers: 3,
          maxPlayers: 4,
        },
      });
      const notDuel = await post(challenger, '/challenges', { gameKey: party.key });
      expect(notDuel.status).toBe(400);
    });
  });

  // -------------------------------------------------------------------------
  // Match history
  // -------------------------------------------------------------------------

  describe('match history', () => {
    it('filters matches by status and rejects unknown filters', async () => {
      const p1 = await registerUser(app);
      const p2 = await registerUser(app);

      const created = await post(p1, '/matches', { gameKey: GAME_KEY });
      expect(created.status).toBe(201);
      const joined = await post(p2, `/matches/${created.body.id}/join`);
      expect(joined.status).toBe(200);

      const activeList = await get(p1, '/matches?status=ACTIVE');
      expect(activeList.status).toBe(200);
      expect(
        (activeList.body.items as Array<Record<string, unknown>>).some(
          (m) => m.id === created.body.id,
        ),
      ).toBe(true);

      const resign = await post(p2, `/matches/${created.body.id}/resign`);
      expect(resign.status).toBe(200);

      const completedList = await get(p1, '/matches?status=COMPLETED');
      expect(completedList.status).toBe(200);
      const entry = (completedList.body.items as Array<Record<string, unknown>>).find(
        (m) => m.id === created.body.id,
      );
      expect(entry).toBeDefined();
      expect(entry?.completedAt).toBeTruthy();
      const players = (entry?.players as Array<Record<string, unknown>>) ?? [];
      const results = new Map(players.map((p) => [p.username, p.result]));
      expect(results.get(p1.username)).toBe('WIN');
      expect(results.get(p2.username)).toBe('LOSS');

      const bogus = await get(p1, '/matches?status=NOPE');
      expect(bogus.status).toBe(400);
    });
  });
});

