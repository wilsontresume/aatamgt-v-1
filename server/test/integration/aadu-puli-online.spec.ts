import { INestApplication } from '@nestjs/common';
import { AddressInfo } from 'node:net';
import { io, Socket } from 'socket.io-client';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, prisma, registerUser } from '../helpers/fixtures';
import {
  AaduPuliRules,
  GameResult,
  GameState,
  MoveKind,
} from '../../src/aadu-puli';

/**
 * Phase 6: real-time Aadu Puli Aattam over WebSocket with two
 * simulated clients. Covers match creation/join, player assignment,
 * turn synchronization, server-side validation, duplicate/stale/illegal
 * moves, simultaneous submits, reconnection, disconnect forfeit, turn
 * timeout, resignation, rematch and match completion.
 *
 * The server decides every rule and result; the clients only submit
 * payloads and render what the server says.
 */

const GAME_KEY = 'aadu-puli-aattam';
const PREV_TURN_TIMEOUT = process.env.MATCH_TURN_TIMEOUT_MS;
const PREV_DISCONNECT_GRACE = process.env.MATCH_DISCONNECT_GRACE_MS;

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** One simulated player: a socket.io client with an event queue. */
class TestClient {
  readonly events: { name: string; data: Record<string, unknown> }[] = [];
  socket!: Socket;

  constructor(
    private readonly url: string,
    private readonly token: string,
  ) {}

  async connect(): Promise<void> {
    this.socket = io(this.url, {
      transports: ['websocket'],
      reconnection: false,
      auth: { token: this.token },
    });
    this.socket.onAny((name, data) => {
      this.events.push({ name, data: data as Record<string, unknown> });
    });
    await new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error('connect timeout')), 5000);
      this.socket.once('connected', () => {
        clearTimeout(timer);
        resolve();
      });
      this.socket.once('error', (payload: unknown) => {
        clearTimeout(timer);
        reject(new Error(`socket error: ${JSON.stringify(payload)}`));
      });
    });
  }

  emitAck(event: string, payload: Record<string, unknown>, timeout = 6000) {
    return this.socket.timeout(timeout).emitWithAck(event, payload) as Promise<
      Record<string, unknown>
    >;
  }

  /** Removes and returns the first queued event matching name+predicate. */
  async take(
    name: string,
    predicate: (data: Record<string, unknown>) => boolean = () => true,
    timeoutMs = 5000,
  ): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const index = this.events.findIndex((e) => e.name === name && predicate(e.data));
      if (index >= 0) return this.events.splice(index, 1)[0].data;
      if (Date.now() > deadline) {
        const seen = this.events.map((e) => e.name).join(',');
        throw new Error(`timeout waiting for ${name} (saw: ${seen || 'nothing'})`);
      }
      await sleep(15);
    }
  }

  close(): void {
    this.socket?.close();
  }
}

describe('Aadu Puli online (integration, two simulated clients)', () => {
  let app: INestApplication;
  let url: string;
  let alice: Awaited<ReturnType<typeof registerUser>>;
  let bob: Awaited<ReturnType<typeof registerUser>>;

  const api = () => app.getHttpServer();

  async function createMatch(creator = alice): Promise<string> {
    const res = await request(api())
      .post(`${apiPrefix(app)}/matches`)
      .set(auth(creator.accessToken))
      .send({ gameKey: GAME_KEY });
    expect(res.status).toBe(201);
    expect(res.body.status).toBe('PENDING');
    return res.body.id as string;
  }

  async function joinMatch(matchId: string, joiner = bob): Promise<void> {
    const res = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/join`)
      .set(auth(joiner.accessToken));
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('ACTIVE');
    // Activation must publish the authoritative engine state.
    const engineState = (res.body.serverState as { state?: { ply?: number } } | null)?.state;
    expect(engineState).toBeDefined();
    expect(engineState?.ply).toBe(0);
  }

  async function freshMatch(): Promise<string> {
    const matchId = await createMatch();
    await joinMatch(matchId);
    return matchId;
  }

  async function newClient(user = alice): Promise<TestClient> {
    const client = new TestClient(url, user.accessToken);
    await client.connect();
    return client;
  }

  beforeAll(async () => {
    // Short clocks so timeout/disconnect tests finish quickly.
    process.env.MATCH_TURN_TIMEOUT_MS = '2500';
    process.env.MATCH_DISCONNECT_GRACE_MS = '600';

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
    await app.listen(0, '127.0.0.1');
    const address = app.getHttpServer().address() as AddressInfo;
    url = `http://127.0.0.1:${address.port}/ws`;
    alice = await registerUser(app);
    bob = await registerUser(app);
  });

  afterAll(async () => {
    await app.close();
    process.env.MATCH_TURN_TIMEOUT_MS = PREV_TURN_TIMEOUT;
    process.env.MATCH_DISCONNECT_GRACE_MS = PREV_DISCONNECT_GRACE;
    if (PREV_TURN_TIMEOUT === undefined) delete process.env.MATCH_TURN_TIMEOUT_MS;
    if (PREV_DISCONNECT_GRACE === undefined) delete process.env.MATCH_DISCONNECT_GRACE_MS;
  });

  // -------------------------------------------------------------------------

  it('creates, joins and assigns seats and sides per player', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);

    const aliceSnap = (await aliceClient.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(aliceSnap.ok).toBe(true);
    expect(aliceSnap.matchId).toBe(matchId);
    expect(aliceSnap.status).toBe('ACTIVE');
    expect(aliceSnap.seat).toBe(0);
    expect(aliceSnap.side).toBe('goats');
    expect((aliceSnap.moves as unknown[]).length).toBe(0);
    expect((aliceSnap.players as unknown[]).length).toBe(2);

    const bobSnap = (await bobClient.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(bobSnap.ok).toBe(true);
    expect(bobSnap.seat).toBe(1);
    expect(bobSnap.side).toBe('tigers');
    const presence = bobSnap.presence as Record<string, boolean>;
    expect(presence[alice.id]).toBe(true);
    expect(presence[bob.id]).toBe(true);

    // Non-participants are refused.
    const outsiderClient = await newClient(await registerUser(app));
    const denied = (await outsiderClient.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(denied).toMatchObject({ ok: false, error: 'not a participant' });

    aliceClient.close();
    bobClient.close();
    outsiderClient.close();
    await sleep(50);
  });

  it('rejects invalid moves, wrong turns, duplicates and stale moves', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    const versionOf = async (): Promise<number> => {
      const res = await request(api())
        .get(`${apiPrefix(app)}/matches/${matchId}`)
        .set(auth(alice.accessToken));
      return res.body.stateVersion as number;
    };
    const moveCount = async (): Promise<number> => {
      const res = await request(api())
        .get(`${apiPrefix(app)}/matches/${matchId}`)
        .set(auth(alice.accessToken));
      return (res.body.moves as unknown[]).length;
    };

    // Wrong player's turn: the tigers cannot move while goats are to move.
    const wrongTurn = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.STEP, from: 0, to: 5 },
    })) as Record<string, unknown>;
    expect(wrongTurn.ok).toBe(false);
    expect(wrongTurn.error).toBe("Not your turn");

    // Invalid move on the right turn: point 0 is occupied by a tiger.
    const occupied = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 0 },
    })) as Record<string, unknown>;
    expect(occupied.ok).toBe(false);
    expect(occupied.error).toBe('That point is already occupied.');

    const versionBefore = await versionOf();

    // A legal move is accepted and broadcast with the next state.
    const accepted = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 7 },
      clientSeq: 1,
    })) as Record<string, unknown>;
    expect(accepted.ok).toBe(true);
    expect(accepted.move).toMatchObject({ seq: 1, notation: '7' });
    expect(accepted.sideToMove).toBe('tigers');
    expect((accepted.state as { ply: number }).ply).toBe(1);

    const broadcast = await bobClient.take(
      'match:moved',
      (data) => (data.seq as number) === 1,
    );
    expect(broadcast.userId).toBe(alice.id);
    expect(broadcast.notation).toBe('7');
    expect(broadcast.sideToMove).toBe('tigers');
    expect(broadcast.turnDeadlineAt).toBeDefined();

    // Duplicate: the same move with the same clientSeq is stale now.
    const duplicate = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 7 },
      clientSeq: 1,
    })) as Record<string, unknown>;
    expect(duplicate.ok).toBe(false);
    expect(String(duplicate.error)).toContain('Out of order move');

    // Stale move without a sequence: it is simply not the player's turn.
    const stale = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 8 },
    })) as Record<string, unknown>;
    expect(stale.ok).toBe(false);
    expect(stale.error).toBe("Not your turn");

    // Illegal tiger moves are rejected by the rules engine.
    const notAdjacent = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.STEP, from: 0, to: 1 },
    })) as Record<string, unknown>;
    expect(notAdjacent.ok).toBe(false);
    expect(notAdjacent.error).toBe('Pieces move along the lines to the next point.');

    const wrongPiece = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.STEP, from: 7, to: 8 },
    })) as Record<string, unknown>;
    expect(wrongPiece.ok).toBe(false);
    expect(wrongPiece.error).toBe("You cannot move your opponent's piece.");

    const malformed = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: 9, to: 5 },
    })) as Record<string, unknown>;
    expect(malformed.ok).toBe(false);
    expect(malformed.error).toBe('Malformed move payload');

    const noPayload = (await bobClient.emitAck('match:move', { matchId })) as Record<
      string,
      unknown
    >;
    expect(noPayload.ok).toBe(false);

    const badSeq = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.STEP, from: 0, to: 5 },
      clientSeq: 0,
    })) as Record<string, unknown>;
    expect(badSeq.ok).toBe(false);

    // Nothing but the legal move was recorded.
    expect(await moveCount()).toBe(1);
    expect(await versionOf()).toBe(versionBefore + 1);

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('accepts exactly one of two simultaneous submits', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    // Two players race. Bob's move is never legal (0 and 1 are not
    // adjacent), so whichever way the server serializes the requests,
    // only Alice's move may land.
    const [aliceResult, bobResult] = await Promise.all([
      aliceClient.emitAck('match:move', {
        matchId,
        payload: { kind: MoveKind.PLACE, to: 7 },
      }) as Promise<Record<string, unknown>>,
      bobClient.emitAck('match:move', {
        matchId,
        payload: { kind: MoveKind.STEP, from: 0, to: 1 },
      }) as Promise<Record<string, unknown>>,
    ]);
    expect(aliceResult.ok).toBe(true);
    expect(bobResult.ok).toBe(false);
    expect(bobResult.error).toMatch(
      /^(Not your turn|Pieces move along the lines to the next point\.)$/,
    );

    let res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId}`)
      .set(auth(alice.accessToken));
    expect((res.body.moves as unknown[]).length).toBe(1);

    // The same player double-submits: exactly one lands.
    const matchId2 = await freshMatch();
    await aliceClient.emitAck('match:subscribe', { matchId: matchId2 });
    const [first, second] = await Promise.all([
      aliceClient.emitAck('match:move', {
        matchId: matchId2,
        payload: { kind: MoveKind.PLACE, to: 7 },
        clientSeq: 1,
      }) as Promise<Record<string, unknown>>,
      aliceClient.emitAck('match:move', {
        matchId: matchId2,
        payload: { kind: MoveKind.PLACE, to: 7 },
        clientSeq: 1,
      }) as Promise<Record<string, unknown>>,
    ]);
    expect([first.ok, second.ok].filter(Boolean)).toHaveLength(1);
    res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId2}`)
      .set(auth(alice.accessToken));
    expect((res.body.moves as unknown[]).length).toBe(1);

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('plays to a server-decided completion with full move history', async () => {
    // Earlier tests close their clients over still-ACTIVE matches; the
    // 600ms disconnect grace then forfeits them asynchronously. Let
    // every pending forfeit land before the baseline so the profile
    // delta counts only this match.
    await sleep(800);
    const aliceProfileBefore = await prisma().profile.findUnique({
      where: { userId: alice.id },
    });
    const bobProfileBefore = await prisma().profile.findUnique({ where: { userId: bob.id } });

    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    // Deterministic line: first legal move, ply for ply (engine parity
    // is pinned by test/unit/aadu-puli.spec.ts).
    let state = GameState.initial();
    let clientSeq = 1;
    while (state.result === GameResult.NONE) {
      const legal = AaduPuliRules.legalMoves(state);
      expect(legal.length).toBeGreaterThan(0);
      const move = legal[0];
      const onTurn = state.sideToMove === 0 ? aliceClient : bobClient;
      const ack = (await onTurn.emitAck('match:move', {
        matchId,
        payload: move.toJSON(),
        clientSeq,
      })) as Record<string, unknown>;
      expect(ack.ok).toBe(true);
      expect((ack.move as { notation: string }).notation).toBe(move.notation());
      const next = AaduPuliRules.apply(state, move)!;
      // The client mirrors the server's state; it never invents one.
      expect(ack.state).toEqual(next.serialize());
      state = next;
      clientSeq += 1;
      expect(clientSeq).toBeLessThanOrEqual(70);
    }

    const completed = await aliceClient.take(
      'match:status',
      (data) => data.status === 'COMPLETED',
    );
    const completion = completed.completed as {
      reason: string;
      winnerSeat: number | null;
      results: Record<string, string>;
    };
    expect(completion.reason).toBe('RULES');
    expect(completion.winnerSeat).toBeNull();
    expect(completion.results[alice.id]).toBe('DRAW');
    expect(completion.results[bob.id]).toBe('DRAW');

    // Completion is persisted and further moves are refused.
    const res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId}?history=200`)
      .set(auth(alice.accessToken));
    expect(res.body.status).toBe('COMPLETED');
    expect(res.body.completedAt).not.toBeNull();
    expect(
      (res.body.players as { userId: string; result: string }[]).every(
        (p) => p.result === 'DRAW',
      ),
    ).toBe(true);
    expect((res.body.moves as unknown[]).length).toBe(clientSeq - 1);

    const afterMove = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 9 },
    })) as Record<string, unknown>;
    expect(afterMove.ok).toBe(false);

    // Move history rows carry a server-computed state hash.
    const rows = await prisma().matchMove.findMany({
      where: { matchId },
      orderBy: { seq: 'asc' },
    });
    expect(rows.length).toBe(clientSeq - 1);
    for (const row of rows) {
      expect(row.stateHash).toMatch(/^[0-9a-f]{64}$/);
    }

    // Server-side rating/record updates (the client never computes these).
    const aliceAfter = await prisma().profile.findUnique({ where: { userId: alice.id } });
    const bobAfter = await prisma().profile.findUnique({ where: { userId: bob.id } });
    expect(aliceAfter!.gamesPlayed).toBe(aliceProfileBefore!.gamesPlayed + 1);
    expect(bobAfter!.gamesPlayed).toBe(bobProfileBefore!.gamesPlayed + 1);
    expect(aliceAfter!.draws).toBe(aliceProfileBefore!.draws + 1);
    expect(bobAfter!.draws).toBe(bobProfileBefore!.draws + 1);

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('restores a disconnected player by reconnection with full history', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    let bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    const first = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 7 },
    })) as Record<string, unknown>;
    expect(first.ok).toBe(true);
    await bobClient.take('match:moved');

    // Bob drops: Alice is told, and a grace clock starts.
    bobClient.close();
    const presenceDown = await aliceClient.take(
      'match:presence',
      (data) => data.userId === bob.id && data.connected === false,
    );
    expect(presenceDown.matchId).toBe(matchId);

    // Bob reconnects within the grace window with a fresh socket.
    bobClient = await newClient(bob);
    const snapshot = (await bobClient.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(snapshot.ok).toBe(true);
    expect(snapshot.seat).toBe(1);
    // 1 from activation + 1 for Alice's move.
    expect(snapshot.stateVersion).toBe(2);
    expect((snapshot.moves as { seq: number }[]).map((m) => m.seq)).toEqual([1]);
    const serverState = snapshot.serverState as { state: { ply: number } };
    expect(serverState.state.ply).toBe(1);
    expect((snapshot.presence as Record<string, boolean>)[bob.id]).toBe(true);

    const presenceUp = await aliceClient.take(
      'match:presence',
      (data) => data.userId === bob.id && data.connected === true,
    );
    expect(presenceUp.matchId).toBe(matchId);

    // The grace clock was cancelled: the match survives past the window.
    await sleep(800);
    const res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId}`)
      .set(auth(alice.accessToken));
    expect(res.body.status).toBe('ACTIVE');

    // Play continues seamlessly after the reconnect.
    const reply = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.STEP, from: 0, to: 5 },
    })) as Record<string, unknown>;
    expect(reply.ok).toBe(true);

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('forfeits a player whose disconnect grace expires', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    bobClient.close();

    const completed = await aliceClient.take(
      'match:status',
      (data) => data.status === 'COMPLETED',
      4000,
    );
    const completion = completed.completed as {
      reason: string;
      winnerSeat: number;
      results: Record<string, string>;
    };
    expect(completion.reason).toBe('DISCONNECT');
    expect(completion.winnerSeat).toBe(0);
    expect(completion.results[alice.id]).toBe('WIN');
    expect(completion.results[bob.id]).toBe('LOSS');

    const res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId}`)
      .set(auth(alice.accessToken));
    expect(res.body.status).toBe('COMPLETED');

    aliceClient.close();
    await sleep(50);
  });

  it('ends the match when a turn deadline expires', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    await aliceClient.emitAck('match:subscribe', { matchId });

    // No one moves: the goats (seat 0) are on the clock from activation.
    const completed = await aliceClient.take(
      'match:status',
      (data) => data.status === 'COMPLETED',
      5000,
    );
    const completion = completed.completed as {
      reason: string;
      winnerSeat: number;
      results: Record<string, string>;
    };
    expect(completion.reason).toBe('TIMEOUT');
    expect(completion.winnerSeat).toBe(1);
    expect(completion.results[alice.id]).toBe('LOSS');
    expect(completion.results[bob.id]).toBe('WIN');

    const late = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { kind: MoveKind.PLACE, to: 7 },
    })) as Record<string, unknown>;
    expect(late.ok).toBe(false);

    aliceClient.close();
    await sleep(50);
  });

  it('resigns over WebSocket and starts a rematch with swapped seats', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    const resigned = (await bobClient.emitAck('match:resign', { matchId })) as Record<
      string,
      unknown
    >;
    expect(resigned.ok).toBe(true);
    expect((resigned.completed as { reason: string }).reason).toBe('RESIGN');

    const completed = await aliceClient.take(
      'match:status',
      (data) => data.status === 'COMPLETED',
    );
    const completion = completed.completed as {
      reason: string;
      winnerSeat: number;
      results: Record<string, string>;
    };
    expect(completion.reason).toBe('RESIGN');
    expect(completion.winnerSeat).toBe(0);
    expect(completion.results[alice.id]).toBe('WIN');
    expect(completion.results[bob.id]).toBe('LOSS');

    // Rematch: a new server-generated match id reaches both players.
    const rematchAck = (await aliceClient.emitAck('match:rematch', { matchId })) as Record<
      string,
      unknown
    >;
    expect(rematchAck.ok).toBe(true);
    const newMatchId = rematchAck.matchId as string;
    expect(newMatchId).not.toBe(matchId);
    expect(rematchAck.status).toBe('ACTIVE');

    const rematchEvent = await bobClient.take('match:rematch');
    expect(rematchEvent.matchId).toBe(matchId);
    expect(rematchEvent.newMatchId).toBe(newMatchId);

    // Idempotent: asking again returns the same match.
    const again = (await aliceClient.emitAck('match:rematch', { matchId })) as Record<
      string,
      unknown
    >;
    expect(again.matchId).toBe(newMatchId);

    // Seats swap so the previous loser gets the goats (who move first).
    const aliceNext = (await aliceClient.emitAck('match:subscribe', {
      matchId: newMatchId,
    })) as Record<string, unknown>;
    const bobNext = (await bobClient.emitAck('match:subscribe', {
      matchId: newMatchId,
    })) as Record<string, unknown>;
    expect(aliceNext.seat).toBe(1);
    expect(aliceNext.side).toBe('tigers');
    expect(bobNext.seat).toBe(0);
    expect(bobNext.side).toBe('goats');

    const opening = (await bobClient.emitAck('match:move', {
      matchId: newMatchId,
      payload: { kind: MoveKind.PLACE, to: 7 },
    })) as Record<string, unknown>;
    expect(opening.ok).toBe(true);
    expect(opening.sideToMove).toBe('tigers');

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('resigns and rematches over REST as well', async () => {
    const matchId = await freshMatch();

    const resigned = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/resign`)
      .set(auth(alice.accessToken));
    expect(resigned.status).toBe(200);
    expect(resigned.body.completed.reason).toBe('RESIGN');
    expect(resigned.body.completed.results[alice.id]).toBe('LOSS');
    expect(resigned.body.completed.results[bob.id]).toBe('WIN');

    // A second resign on the finished match is refused.
    const again = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/resign`)
      .set(auth(bob.accessToken));
    expect(again.status).toBe(409);

    const rematch = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/rematch`)
      .set(auth(bob.accessToken));
    expect(rematch.status).toBe(200);
    expect(rematch.body.status).toBe('ACTIVE');
    expect(rematch.body.id).not.toBe(matchId);

    const rematchAgain = await request(api())
      .post(`${apiPrefix(app)}/matches/${matchId}/rematch`)
      .set(auth(bob.accessToken));
    expect(rematchAgain.body.id).toBe(rematch.body.id);
  });

  it('refuses moves and subscriptions from outsiders over the socket', async () => {
    const matchId = await freshMatch();
    const outsider = await newClient(await registerUser(app));
    const denied = (await outsider.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(denied).toMatchObject({ ok: false, error: 'not a participant' });
    const pong = (await outsider.emitAck('ping', {})) as Record<string, unknown>;
    expect(pong.ok).toBe(true);
    outsider.close();
    await sleep(50);
  });
});
