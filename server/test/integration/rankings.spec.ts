import { INestApplication } from '@nestjs/common';
import request from 'supertest';
import { createTestApp, uniqueSuffix } from '../helpers/app';
import { apiPrefix, auth, createUserDirectly, registerUser } from '../helpers/fixtures';
import { PrismaService } from '../../src/prisma/prisma.service';
import { RankingsService } from '../../src/rankings/rankings.service';
import {
  RANK_TIERS,
  START_RATING,
  eloDelta,
  rankForRating,
} from '../../src/rankings/ranks';

const GAME_KEY = 'aadu-puli-aattam';

describe('Rankings (integration)', () => {
  let app: INestApplication;
  let alice: Awaited<ReturnType<typeof registerUser>>;
  let bob: Awaited<ReturnType<typeof registerUser>>;
  let rankings: RankingsService;
  let prisma: PrismaService;
  let matchId: string;
  let activeSeasonKey: string;

  const api = () => app.getHttpServer();

  beforeAll(async () => {
    app = await createTestApp();
    rankings = app.get(RankingsService);
    prisma = app.get(PrismaService);
    [alice, bob] = await Promise.all([registerUser(app), registerUser(app)]);
  });

  afterAll(async () => {
    await app.close();
  });

  async function startRatedMatch(): Promise<string> {
    const created = await request(api())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(alice.accessToken))
      .send({ gameKey: GAME_KEY });
    expect(created.status).toBe(201);
    const joined = await request(api())
      .post(`${apiPrefix(app)}/matches/${created.body.id}/join`)
      .set(auth(bob.accessToken));
    expect(joined.status).toBe(200);
    return created.body.id as string;
  }

  it('serves a default summary of three rated games in the active season', async () => {
    const res = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    expect(res.status).toBe(200);
    // The shared test database may already carry seasons from earlier
    // runs — the active season must simply be well-formed.
    expect(res.body.season.key).toMatch(/^season-\d+$/);
    expect(res.body.season.name).toBe(
      `Season ${res.body.season.key.replace('season-', '')}`,
    );
    activeSeasonKey = res.body.season.key;
    expect(res.body.games.map((g: { gameKey: string }) => g.gameKey)).toEqual([
      'aadu-puli-aattam',
      'solah-seedi',
      'nine-mens-morris',
    ]);
    for (const game of res.body.games) {
      expect(game.rating).toBe(START_RATING);
      expect(game.rank.key).toBe('bronze');
      expect(game.wins).toBe(0);
      expect(game.losses).toBe(0);
      expect(game.draws).toBe(0);
      expect(game.gamesPlayed).toBe(0);
      expect(game.position).toBeGreaterThanOrEqual(1);
    }
  });

  it('maps every rating band onto the six ranks', () => {
    expect(RANK_TIERS.map((t) => t.key)).toEqual([
      'bronze',
      'silver',
      'gold',
      'platinum',
      'diamond',
      'master',
    ]);
    expect(rankForRating(START_RATING).key).toBe('bronze');
    expect(rankForRating(1099).key).toBe('bronze');
    expect(rankForRating(1100).key).toBe('silver');
    expect(rankForRating(1299).key).toBe('silver');
    expect(rankForRating(1300).key).toBe('gold');
    expect(rankForRating(1500).key).toBe('platinum');
    expect(rankForRating(1700).key).toBe('diamond');
    expect(rankForRating(1900).key).toBe('master');
    expect(rankForRating(9999).key).toBe('master');
    expect(eloDelta(1000, 1000, 1)).toBe(8);
    expect(eloDelta(1000, 1000, 0)).toBe(-8);
    expect(eloDelta(1200, 1000, 1)).toBeGreaterThan(0);
  });

  it('moves ratings only once a server-authoritative match completes', async () => {
    matchId = await startRatedMatch();

    const during = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    expect(during.status).toBe(200);
    expect(during.body.games[0].rating).toBe(START_RATING);
    const duringHistory = await request(api())
      .get(`${apiPrefix(app)}/rankings/history`)
      .set(auth(alice.accessToken));
    expect(duringHistory.body.items).toHaveLength(0);

    const resign = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/resign`)
      .set(auth(bob.accessToken));
    expect(resign.status).toBe(200);
    expect(resign.body.completed.results[alice.id]).toBe('WIN');
    expect(resign.body.completed.results[bob.id]).toBe('LOSS');

    const aliceSummary = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    const aadu = aliceSummary.body.games[0];
    expect(aadu.rating).toBe(1008);
    expect(aadu.rank.key).toBe('bronze');
    expect(aadu.wins).toBe(1);
    expect(aadu.gamesPlayed).toBe(1);
    expect(aadu.position).toBeGreaterThanOrEqual(1);
    // The other two games stay untouched — each game has its own rating.
    expect(aliceSummary.body.games[1].rating).toBe(START_RATING);
    expect(aliceSummary.body.games[1].gamesPlayed).toBe(0);
    expect(aliceSummary.body.games[2].rating).toBe(START_RATING);

    const bobSummary = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(bob.accessToken));
    expect(bobSummary.body.games[0].rating).toBe(992);
    expect(bobSummary.body.games[0].losses).toBe(1);
    expect(bobSummary.body.games[0].position).toBeGreaterThan(aadu.position);

    const history = await request(api())
      .get(`${apiPrefix(app)}/rankings/history`)
      .set(auth(alice.accessToken));
    expect(history.body.items).toHaveLength(1);
    expect(history.body.items[0]).toMatchObject({
      matchId,
      gameKey: GAME_KEY,
      result: 'WIN',
      reason: 'RESIGN',
      ratingBefore: 1000,
      delta: 8,
      ratingAfter: 1008,
      seasonKey: activeSeasonKey,
      opponent: bob.username,
    });

    const filtered = await request(api())
      .get(`${apiPrefix(app)}/rankings/history?gameKey=nine-mens-morris`)
      .set(auth(alice.accessToken));
    expect(filtered.body.items).toHaveLength(0);
  });

  it('refuses duplicate match-result submissions', async () => {
    const again = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/resign`)
      .set(auth(bob.accessToken));
    expect(again.status).toBe(409);

    const eventCount = () =>
      prisma.ratingEvent.count({ where: { matchId } });
    expect(await eventCount()).toBe(2);

    // Even a direct service-level re-apply is a no-op: the unique
    // (matchId, userId) key means a result can never count twice.
    const match = await prisma.gameMatch.findUnique({
      where: { id: matchId },
      include: { players: true },
    });
    expect(match).not.toBeNull();
    const results = new Map<string, 'WIN' | 'LOSS' | 'DRAW'>([
      [alice.id, 'WIN'],
      [bob.id, 'LOSS'],
    ]);
    const replay = await rankings.applyMatchResult(
      prisma,
      match!,
      { winnerSeat: 0, reason: 'RESIGN' },
      results,
    );
    expect(replay).toHaveLength(0);
    expect(await eventCount()).toBe(2);

    const aliceSummary = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    expect(aliceSummary.body.games[0].rating).toBe(1008);
    expect(aliceSummary.body.games[0].gamesPlayed).toBe(1);
  });

  it('orders the leaderboard by rating, only rated competitors', async () => {
    const board = await request(api())
      .get(`${apiPrefix(app)}/rankings/leaderboard?gameKey=${GAME_KEY}`);
    expect(board.status).toBe(200);
    expect(board.body.season.key).toBe(activeSeasonKey);
    // Other suites' players share this board — assert our two and the order.
    const usernames = board.body.items.map((i: { username: string }) => i.username);
    expect(usernames).toContain(alice.username);
    expect(usernames).toContain(bob.username);
    const ratings = board.body.items.map((i: { rating: number }) => i.rating);
    expect([...ratings].sort((a, b) => b - a)).toEqual(ratings);
    const aliceItem = board.body.items.find((i: { username: string }) => i.username === alice.username);
    const bobItem = board.body.items.find((i: { username: string }) => i.username === bob.username);
    expect(aliceItem).toMatchObject({
      rating: 1008,
      wins: 1,
      rank: { key: 'bronze', name: 'Bronze' },
    });
    expect(bobItem).toMatchObject({ rating: 992, losses: 1 });
    expect(aliceItem.position).toBeLessThan(bobItem.position);
    expect(aliceItem.position).toBeGreaterThanOrEqual(1);

    // Scoping: neither player has touched 16 Soldiers, so neither may
    // appear on that game's board.
    const unrated = await request(api())
      .get(`${apiPrefix(app)}/rankings/leaderboard?gameKey=solah-seedi`);
    expect(unrated.status).toBe(200);
    const solahNames = unrated.body.items.map((i: { username: string }) => i.username);
    expect(solahNames).not.toContain(alice.username);
    expect(solahNames).not.toContain(bob.username);

    const invalid = await request(api())
      .get(`${apiPrefix(app)}/rankings/leaderboard?gameKey=chess`);
    expect(invalid.status).toBe(400);
  });

  it('keeps seasons scoped and rollover admin-only', async () => {
    const before = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    const previousKey = before.body.season.key;

    const denied = await request(api())
      .post(`${apiPrefix(app)}/rankings/seasons`)
      .set(auth(alice.accessToken));
    expect(denied.status).toBe(403);

    const admin = await createUserDirectly(`rk_${uniqueSuffix()}`.slice(0, 24), 'ADMIN');
    const loginRes = await request(api())
      .post(`${apiPrefix(app)}/auth/login`)
      .send({ identifier: admin.username, password: admin.password });
    expect(loginRes.status).toBe(200);
    const rolled = await request(api())
      .post(`${apiPrefix(app)}/rankings/seasons`)
      .set(auth(loginRes.body.accessToken));
    expect(rolled.status).toBe(201);
    expect(rolled.body.key).toMatch(/^season-\d+$/);
    expect(rolled.body.key).not.toBe(previousKey);
    expect(rolled.body.isActive).toBe(true);

    const summary = await request(api())
      .get(`${apiPrefix(app)}/rankings/summary`)
      .set(auth(alice.accessToken));
    expect(summary.body.season.key).toBe(rolled.body.key);
    expect(summary.body.games[0].rating).toBe(START_RATING);
    expect(summary.body.games[0].gamesPlayed).toBe(0);

    const history = await request(api())
      .get(`${apiPrefix(app)}/rankings/history`)
      .set(auth(alice.accessToken));
    expect(history.body.items).toHaveLength(1);
    expect(history.body.items[0].seasonKey).toBe(activeSeasonKey);

    const board = await request(api())
      .get(`${apiPrefix(app)}/rankings/leaderboard?gameKey=${GAME_KEY}`);
    expect(board.body.season.key).toBe(rolled.body.key);
    // Fresh season: our players have no rated games in it yet (parallel
    // suites may have completed their own matches meanwhile).
    const freshNames = board.body.items.map((i: { username: string }) => i.username);
    expect(freshNames).not.toContain(alice.username);
    expect(freshNames).not.toContain(bob.username);
  });
});
