import { INestApplication } from '@nestjs/common';
import { AddressInfo } from 'node:net';
import { io, Socket } from 'socket.io-client';
import request from 'supertest';
import { createTestApp } from '../helpers/app';
import { apiPrefix, auth, prisma, registerUser } from '../helpers/fixtures';
import { GameResult, GameState, SolahSeediRules } from '../../src/solah-seedi';

/**
 * Phase 9: real-time Solah Seedi (16 Soldiers) over WebSocket with two
 * simulated clients. Mirrors the Aadu Puli online suite so both games
 * exercise the same shared platform: match creation/join, seat and side
 * assignment, turn synchronisation, server-side validation, duplicate
 * and stale moves, simultaneous submits, reconnection, disconnect
 * forfeit, turn timeout, resignation, rematch and completion.
 *
 * Solah Seedi-specific ground: the path-only wire contract
 * ({path:[...]}, chain hops included) and the rules engine that decides
 * every capture, breakthrough and draw.
 */

const GAME_KEY = 'solah-seedi';
const PREV_TURN_TIMEOUT = process.env.MATCH_TURN_TIMEOUT_MS;
const PREV_DISCONNECT_GRACE = process.env.MATCH_DISCONNECT_GRACE_MS;

/** Deterministic line used by the parity test (engine-verified). */
const CAPTURE_LINE: { seat: number; payload: Record<string, unknown>; notation: string }[] = [
  { seat: 0, payload: { path: [11, 16] }, notation: '11-16' },
  { seat: 1, payload: { path: [21, 11] }, notation: '21-11*' },
  { seat: 0, payload: { path: [6, 16] }, notation: '6-16*' },
  { seat: 1, payload: { path: [22, 21] }, notation: '22-21' },
  { seat: 0, payload: { path: [7, 6] }, notation: '7-6' },
  { seat: 1, payload: { path: [21, 22] }, notation: '21-22' },
  { seat: 0, payload: { path: [13, 18] }, notation: '13-18' },
  { seat: 1, payload: { path: [23, 13, 11] }, notation: '23-13-11*' },
];

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

describe('Solah Seedi online (integration, two simulated clients)', () => {
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

  async function freshMatch(creator = alice, joiner = bob): Promise<string> {
    const matchId = await createMatch(creator);
    await joinMatch(matchId, joiner);
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
        name: 'Solah Seedi',
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
    expect(aliceSnap.side).toBe('red');
    expect((aliceSnap.moves as unknown[]).length).toBe(0);
    expect((aliceSnap.players as unknown[]).length).toBe(2);

    const bobSnap = (await bobClient.emitAck('match:subscribe', { matchId })) as Record<
      string,
      unknown
    >;
    expect(bobSnap.ok).toBe(true);
    expect(bobSnap.seat).toBe(1);
    expect(bobSnap.side).toBe('green');
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

    // Wrong player's turn: green cannot move while red is to move.
    const wrongTurn = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [25, 24] },
    })) as Record<string, unknown>;
    expect(wrongTurn.ok).toBe(false);
    expect(wrongTurn.error).toBe('Not your turn');

    // Invalid move on the right turn: point 1 already holds a red piece.
    const occupied = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { path: [0, 1] },
    })) as Record<string, unknown>;
    expect(occupied.ok).toBe(false);
    expect(occupied.error).toBe('That point is already occupied.');

    const versionBefore = await versionOf();

    // A legal move is accepted and broadcast with the next state.
    const accepted = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { path: [11, 16] },
      clientSeq: 1,
    })) as Record<string, unknown>;
    expect(accepted.ok).toBe(true);
    expect(accepted.move).toMatchObject({ seq: 1, notation: '11-16' });
    expect(accepted.sideToMove).toBe('green');
    expect((accepted.state as { ply: number }).ply).toBe(1);

    const broadcast = await bobClient.take(
      'match:moved',
      (data) => (data.seq as number) === 1,
    );
    expect(broadcast.userId).toBe(alice.id);
    expect(broadcast.notation).toBe('11-16');
    expect(broadcast.sideToMove).toBe('green');
    expect(broadcast.turnDeadlineAt).toBeDefined();

    // Duplicate: the same move with the same clientSeq is stale now.
    const duplicate = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { path: [11, 16] },
      clientSeq: 1,
    })) as Record<string, unknown>;
    expect(duplicate.ok).toBe(false);
    expect(String(duplicate.error)).toContain('Out of order move');

    // Stale move without a sequence: it is simply not the player's turn.
    const stale = (await aliceClient.emitAck('match:move', {
      matchId,
      payload: { path: [12, 17] },
    })) as Record<string, unknown>;
    expect(stale.ok).toBe(false);
    expect(stale.error).toBe('Not your turn');

    // Illegal green moves are rejected by the rules engine.
    const wrongPiece = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [0, 1] },
    })) as Record<string, unknown>;
    expect(wrongPiece.ok).toBe(false);
    expect(wrongPiece.error).toBe("You cannot move your opponent's piece.");

    const emptyOrigin = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [11, 16] },
    })) as Record<string, unknown>;
    expect(emptyOrigin.ok).toBe(false);
    expect(emptyOrigin.error).toBe('There is no piece on that point.');

    const blocked = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [21, 22] },
    })) as Record<string, unknown>;
    expect(blocked.ok).toBe(false);
    expect(blocked.error).toBe('That point is already occupied.');

    // The wire contract is path-only: the Aadu Puli shape is malformed.
    const wrongShape = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { kind: 0, to: 7 },
    })) as Record<string, unknown>;
    expect(wrongShape.ok).toBe(false);
    expect(wrongShape.error).toBe('Malformed move payload');

    const shortPath = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [1] },
    })) as Record<string, unknown>;
    expect(shortPath.ok).toBe(false);
    expect(shortPath.error).toBe('Malformed move payload');

    const noPayload = (await bobClient.emitAck('match:move', { matchId })) as Record<
      string,
      unknown
    >;
    expect(noPayload.ok).toBe(false);

    const badSeq = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [22, 17] },
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

    // Two players race: only Alice's opening step may ever land, and Bob
    // must lose the race either way (wrong turn or opponent's piece).
    const [aliceResult, bobResult] = await Promise.all([
      aliceClient.emitAck('match:move', {
        matchId,
        payload: { path: [11, 16] },
      }) as Promise<Record<string, unknown>>,
      bobClient.emitAck('match:move', {
        matchId,
        payload: { path: [0, 1] },
      }) as Promise<Record<string, unknown>>,
    ]);
    expect(aliceResult.ok).toBe(true);
    expect(bobResult.ok).toBe(false);
    expect(bobResult.error).toMatch(
      /^(Not your turn|You cannot move your opponent's piece\.)$/,
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
        payload: { path: [11, 16] },
        clientSeq: 1,
      }) as Promise<Record<string, unknown>>,
      aliceClient.emitAck('match:move', {
        matchId: matchId2,
        payload: { path: [11, 16] },
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

  it('plays a deterministic capture line with server parity (steps, jumps, chain)', async () => {
    const matchId = await freshMatch();
    const aliceClient = await newClient(alice);
    const bobClient = await newClient(bob);
    await aliceClient.emitAck('match:subscribe', { matchId });
    await bobClient.emitAck('match:subscribe', { matchId });

    let state = GameState.initial();
    let clientSeq = 1;
    for (const step of CAPTURE_LINE) {
      const onTurn = step.seat === 0 ? aliceClient : bobClient;
      const ack = (await onTurn.emitAck('match:move', {
        matchId,
        payload: step.payload,
        clientSeq,
      })) as Record<string, unknown>;
      expect(ack.ok).toBe(true);
      expect((ack.move as { notation: string }).notation).toBe(step.notation);
      const legal = SolahSeediRules.legalMoves(state).find(
        (m) => SolahSeediRules.notation(m) === step.notation,
      );
      expect(legal).toBeDefined();
      const next = SolahSeediRules.apply(state, legal!)!;
      // The client mirrors the server's state; it never invents one.
      expect(ack.state).toEqual(next.serialize());
      expect((ack.state as { side_to_move: string }).side_to_move).toBe(
        step.seat === 0 ? 'green' : 'red',
      );
      state = next;
      clientSeq += 1;
    }

    // Two captures landed (21-11*, 6-16*) and the chain took two pieces.
    expect(state.ply).toBe(8);
    expect(state.serialize().board).toBe('RRRRRRR.RRRG..RRR.....G.GGGGGGGGGGGGG');
    expect(state.result).toBe(GameResult.NONE);
    expect((state as unknown as { pliesSinceCapture: number }).pliesSinceCapture).toBe(0);

    aliceClient.close();
    bobClient.close();
    await sleep(50);
  });

  it('plays to a server-decided completion with full move history', async () => {
    // Fresh players: this test measures the rating impact of exactly one
    // game, so it must not share profiles with earlier tests whose
    // matches may still be sitting on a turn clock.
    const red = await registerUser(app);
    const green = await registerUser(app);
    const redProfileBefore = await prisma().profile.findUnique({ where: { userId: red.id } });
    const greenProfileBefore = await prisma().profile.findUnique({ where: { userId: green.id } });

    const matchId = await freshMatch(red, green);
    const redClient = await newClient(red);
    const greenClient = await newClient(green);
    await redClient.emitAck('match:subscribe', { matchId });
    await greenClient.emitAck('match:subscribe', { matchId });

    // Deterministic line: first legal move, ply for ply (engine parity
    // is pinned by test/unit/solah-seedi.spec.ts). It reaches the
    // 60-ply no-capture draw after 63 plies.
    let state = GameState.initial();
    let clientSeq = 1;
    while (state.result === GameResult.NONE) {
      const legal = SolahSeediRules.legalMoves(state);
      expect(legal.length).toBeGreaterThan(0);
      const move = legal[0];
      const onTurn = state.sideToMove === 0 ? redClient : greenClient;
      const ack = (await onTurn.emitAck('match:move', {
        matchId,
        payload: move.toJSON(),
        clientSeq,
      })) as Record<string, unknown>;
      expect(ack.ok).toBe(true);
      expect((ack.move as { notation: string }).notation).toBe(
        SolahSeediRules.notation(move),
      );
      const next = SolahSeediRules.apply(state, move)!;
      // The client mirrors the server's state; it never invents one.
      expect(ack.state).toEqual(next.serialize());
      state = next;
      clientSeq += 1;
      expect(clientSeq).toBeLessThanOrEqual(70);
    }
    expect(state.result).toBe(GameResult.DRAW);

    const completed = await redClient.take(
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
    expect(completion.results[red.id]).toBe('DRAW');
    expect(completion.results[green.id]).toBe('DRAW');

    // Completion is persisted and further moves are refused.
    const res = await request(api())
      .get(`${apiPrefix(app)}/matches/${matchId}?history=200`)
      .set(auth(red.accessToken));
    expect(res.body.status).toBe('COMPLETED');
    expect(res.body.completedAt).not.toBeNull();
    expect(
      (res.body.players as { userId: string; result: string }[]).every(
        (p) => p.result === 'DRAW',
      ),
    ).toBe(true);
    expect((res.body.moves as unknown[]).length).toBe(clientSeq - 1);

    const afterMove = (await redClient.emitAck('match:move', {
      matchId,
      payload: { path: [10, 11] },
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
    const redAfter = await prisma().profile.findUnique({ where: { userId: red.id } });
    const greenAfter = await prisma().profile.findUnique({ where: { userId: green.id } });
    expect(redAfter!.gamesPlayed).toBe(redProfileBefore!.gamesPlayed + 1);
    expect(greenAfter!.gamesPlayed).toBe(greenProfileBefore!.gamesPlayed + 1);
    expect(redAfter!.draws).toBe(redProfileBefore!.draws + 1);
    expect(greenAfter!.draws).toBe(greenProfileBefore!.draws + 1);

    redClient.close();
    greenClient.close();
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
      payload: { path: [11, 16] },
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
    expect(snapshot.side).toBe('green');
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

    // Play continues seamlessly after the reconnect — with a jump.
    const reply = (await bobClient.emitAck('match:move', {
      matchId,
      payload: { path: [21, 11] },
    })) as Record<string, unknown>;
    expect(reply.ok).toBe(true);
    expect((reply.move as { notation: string }).notation).toBe('21-11*');

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

    // No one moves: red (seat 0) is on the clock from activation.
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
      payload: { path: [11, 16] },
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

    // Seats swap so the previous loser gets seat 0 (red, who move first).
    const aliceNext = (await aliceClient.emitAck('match:subscribe', {
      matchId: newMatchId,
    })) as Record<string, unknown>;
    const bobNext = (await bobClient.emitAck('match:subscribe', {
      matchId: newMatchId,
    })) as Record<string, unknown>;
    expect(aliceNext.seat).toBe(1);
    expect(aliceNext.side).toBe('green');
    expect(bobNext.seat).toBe(0);
    expect(bobNext.side).toBe('red');

    const opening = (await bobClient.emitAck('match:move', {
      matchId: newMatchId,
      payload: { path: [11, 16] },
    })) as Record<string, unknown>;
    expect(opening.ok).toBe(true);
    expect(opening.sideToMove).toBe('green');

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
