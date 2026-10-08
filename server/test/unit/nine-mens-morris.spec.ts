import {
  Cell,
  EDGES,
  GameResult,
  GameState,
  INITIAL_BOARD,
  Issue,
  MILLS,
  Move,
  NONE_CAPTURE,
  NineMensMorrisRules,
  Phase,
  PLIES_TO_DRAW,
  POINT_COUNT,
  Side,
  errorText,
  legalNotations,
  stateHash,
  validate,
} from '../../src/nine-mens-morris';

/**
 * Server-side rules engine suite for Nine Men's Morris, built against
 * docs/nine_mens_morris_rules.md. Geometry, mill tables, phase logic,
 * capture rules, wins, draws and serialization are cross-checked.
 */

type Piece = 'R' | 'G' | '.';

const boardOf = (layout: Partial<Record<number, Piece>>): number[] =>
  Array.from({ length: POINT_COUNT }, (_, p) => {
    const cell = layout[p];
    return cell === 'R' ? Cell.RED : cell === 'G' ? Cell.GREEN : Cell.EMPTY;
  });

const buildState = (opts: {
  layout?: Partial<Record<number, Piece>>;
  toMove?: Side;
  hands?: [number, number];
  ply?: number;
  since?: number;
  result?: GameResult;
  history?: string[];
} = {}): GameState => {
  const state = new GameState(
    boardOf(opts.layout ?? {}),
    opts.toMove ?? Side.RED,
    opts.hands ?? [0, 0],
    opts.ply ?? 0,
    opts.since ?? 0,
    opts.result ?? GameResult.NONE,
    opts.history ?? [],
  );
  if (opts.history === undefined) state.history = [state.repetitionKey()];
  return state;
};

describe('board topology', () => {
  test('there are 24 points, 32 edges and 16 mills', () => {
    expect(POINT_COUNT).toBe(24);
    expect(EDGES).toHaveLength(32);
    expect(MILLS).toHaveLength(16);
  });

  test('every edge joins distinct in-range points, without duplicates', () => {
    const seen = new Set<string>();
    for (const [a, b] of EDGES) {
      expect(a).toBeGreaterThanOrEqual(0);
      expect(b).toBeLessThan(POINT_COUNT);
      expect(a).not.toBe(b);
      const key = a < b ? `${a}-${b}` : `${b}-${a}`;
      expect(seen.has(key)).toBe(false);
      seen.add(key);
      expect(NineMensMorrisRules.areAdjacent(a, b)).toBe(true);
      expect(NineMensMorrisRules.areAdjacent(b, a)).toBe(true);
    }
  });

  test('neighbor sets match the specification exactly', () => {
    expect([...NineMensMorrisRules.neighbors(0)].sort((a, b) => a - b)).toEqual([1, 7]);
    expect([...NineMensMorrisRules.neighbors(1)].sort((a, b) => a - b)).toEqual([0, 2, 9]);
    expect([...NineMensMorrisRules.neighbors(9)].sort((a, b) => a - b)).toEqual([1, 8, 10, 17]);
    expect([...NineMensMorrisRules.neighbors(15)].sort((a, b) => a - b)).toEqual([7, 8, 14, 23]);
    expect([...NineMensMorrisRules.neighbors(23)].sort((a, b) => a - b)).toEqual([15, 16, 22]);
    expect([...NineMensMorrisRules.neighbors(19)].sort((a, b) => a - b)).toEqual([11, 18, 20]);
  });

  test('non-edges are not adjacent', () => {
    expect(NineMensMorrisRules.areAdjacent(0, 2)).toBe(false);
    expect(NineMensMorrisRules.areAdjacent(1, 3)).toBe(false);
    expect(NineMensMorrisRules.areAdjacent(9, 15)).toBe(false);
    expect(NineMensMorrisRules.areAdjacent(17, 19)).toBe(false);
    expect(NineMensMorrisRules.areAdjacent(0, 8)).toBe(false);
    expect(NineMensMorrisRules.areAdjacent(16, 1)).toBe(false);
  });

  test('degree sum is twice the edge count', () => {
    let degreeSum = 0;
    for (let p = 0; p < POINT_COUNT; p++) degreeSum += NineMensMorrisRules.neighbors(p).length;
    expect(degreeSum).toBe(64);
  });

  test('each mill is three consecutive points along its line', () => {
    for (const mill of MILLS) {
      expect(mill).toHaveLength(3);
      expect(NineMensMorrisRules.areAdjacent(mill[0], mill[1])).toBe(true);
      expect(NineMensMorrisRules.areAdjacent(mill[1], mill[2])).toBe(true);
    }
  });

  test('mill tables are exactly the documented 16 lines', () => {
    const expected = [
      '0,1,2', '2,3,4', '4,5,6', '6,7,0',
      '8,9,10', '10,11,12', '12,13,14', '14,15,8',
      '16,17,18', '18,19,20', '20,21,22', '22,23,16',
      '1,9,17', '3,11,19', '5,13,21', '7,15,23',
    ];
    expect(MILLS.map((m) => m.join(','))).toEqual(expected);
  });
});

describe('phases', () => {
  test('a non-empty hand means placement regardless of board', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'R' }, hands: [7, 9] });
    expect(NineMensMorrisRules.phaseOf(state, Side.RED)).toBe<Phase>('placement');
    expect(NineMensMorrisRules.phaseOf(state, Side.GREEN)).toBe<Phase>('placement');
  });

  test('four or more pieces with an empty hand is movement', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'R', 4: 'R', 8: 'R' }, hands: [0, 5] });
    expect(NineMensMorrisRules.phaseOf(state, Side.RED)).toBe<Phase>('movement');
    expect(NineMensMorrisRules.phaseOf(state, Side.GREEN)).toBe<Phase>('placement');
  });

  test('exactly three pieces with an empty hand is flying', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'R', 4: 'R', 8: 'G' }, hands: [0, 0] });
    expect(NineMensMorrisRules.phaseOf(state, Side.RED)).toBe<Phase>('flying');
    expect(NineMensMorrisRules.phaseOf(state, Side.GREEN)).toBe<Phase>('movement');
  });
});

describe('placement phase', () => {
  test('the opening position allows all 24 placements and nothing else', () => {
    const state = GameState.initial();
    const moves = NineMensMorrisRules.legalMoves(state);
    expect(moves).toHaveLength(24);
    expect(moves.every((m) => m.kind === 'place' && m.capture === NONE_CAPTURE)).toBe(true);
    expect(validate(state, moves[0]).ok).toBe(true);
  });

  test('occupied points cannot be placed onto', () => {
    const state = buildState({ layout: { 0: 'G' }, hands: [9, 8] });
    const verdict = validate(state, Move.place(0));
    expect(verdict.ok).toBe(false);
    expect(verdict.issue).toBe(Issue.OCCUPIED);
  });

  test('placing with an empty hand is rejected', () => {
    const state = buildState({ layout: { 0: 'R' }, hands: [0, 9] });
    const verdict = validate(state, Move.place(5));
    expect(verdict.ok).toBe(false);
    expect(verdict.issue).toBe(Issue.HAND_EMPTY);
  });

  test('out-of-range points are rejected before phase checks', () => {
    const state = GameState.initial();
    const verdict = validate(state, Move.place(24));
    expect(verdict.issue).toBe(Issue.OUT_OF_RANGE);
    expect(validate(state, Move.place(-1)).issue).toBe(Issue.OUT_OF_RANGE);
  });
});

describe('movement and flying', () => {
  test('a piece in hand blocks movement', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'G' }, toMove: Side.RED, hands: [8, 9] });
    const verdict = validate(state, Move.step(0, 7));
    expect(verdict.issue).toBe(Issue.MOVE_WITH_HAND);
  });

  test('steps must follow a single edge', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'G', 3: 'G', 8: 'G' }, hands: [0, 9] });
    expect(validate(state, Move.step(0, 7)).ok).toBe(true);
    expect(validate(state, Move.step(0, 2)).issue).toBe(Issue.NOT_ADJACENT);
    expect(validate(state, Move.step(0, 8)).issue).toBe(Issue.OCCUPIED);
  });

  test('origin must hold the mover’s piece', () => {
    const state = buildState({ layout: { 0: 'G', 1: 'R' }, hands: [0, 9] });
    expect(validate(state, Move.step(0, 7)).issue).toBe(Issue.NOT_YOUR_PIECE);
    expect(validate(state, Move.step(5, 4)).issue).toBe(Issue.EMPTY_ORIGIN);
  });

  test('destination must be empty', () => {
    const state = buildState({ layout: { 0: 'R', 7: 'G' }, hands: [0, 9] });
    expect(validate(state, Move.step(0, 7)).issue).toBe(Issue.OCCUPIED);
  });

  test('with exactly three pieces a piece may fly across the board', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 4: 'R', 8: 'G', 12: 'G' },
      hands: [0, 7],
    });
    const flying = validate(state, Move.step(0, 18));
    expect(flying.ok).toBe(true);
    const moves = NineMensMorrisRules.legalMoves(state);
    expect(moves.some((m) => m.from === 0 && m.to === 18)).toBe(true);
    expect(moves.some((m) => m.from === 0 && m.to === 6)).toBe(true);
  });

  test('four pieces may not fly', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 4: 'R', 6: 'R', 8: 'G' },
      hands: [0, 7],
    });
    expect(validate(state, Move.step(0, 18)).issue).toBe(Issue.NOT_ADJACENT);
  });

  test('moving while pieces remain in hand is rejected', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'G' }, hands: [8, 9] });
    expect(validate(state, Move.step(0, 7)).issue).toBe(Issue.MOVE_WITH_HAND);
  });
});

describe('mill detection and capture', () => {
  test('the placement completing a mill requires a capture', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 8: 'G', 10: 'G' },
      toMove: Side.RED,
      hands: [6, 7],
    });
    const plain = validate(state, Move.place(2));
    expect(plain.issue).toBe(Issue.CAPTURE_REQUIRED);
    const variants = NineMensMorrisRules.legalMovesLanding(state, 2);
    expect(variants.map((m) => m.capture).sort((a, b) => a - b)).toEqual([8, 10]);
    expect(validate(state, Move.place(2, 8)).ok).toBe(true);
    expect(validate(state, Move.place(2, 10)).ok).toBe(true);
  });

  test('a capture without a mill is rejected', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'R', 8: 'G' }, hands: [7, 8] });
    const verdict = validate(state, Move.place(3, 8));
    expect(verdict.issue).toBe(Issue.CAPTURE_FORBIDDEN);
  });

  test('pieces outside mills are the only legal targets while one exists', () => {
    // Greens hold a mill at 8-9-10 plus a loose piece at 13.
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 8: 'G', 9: 'G', 10: 'G', 13: 'G' },
      toMove: Side.RED,
      hands: [6, 5],
    });
    const inMill = validate(state, Move.place(2, 8));
    expect(inMill.issue).toBe(Issue.CAPTURE_TARGET);
    expect(validate(state, Move.place(2, 13)).ok).toBe(true);
    const targets = NineMensMorrisRules.captureTargets(
      [...boardOf({ 0: 'R', 1: 'R', 2: 'R', 8: 'G', 9: 'G', 10: 'G', 13: 'G' })],
      Cell.RED,
    );
    expect(targets).toEqual([13]);
  });

  test('when every enemy piece sits in a mill they may all be taken', () => {
    const layout = { 0: 'R', 1: 'R', 8: 'G', 9: 'G', 10: 'G' } as const;
    const state = buildState({ layout, toMove: Side.RED, hands: [6, 6] });
    expect(validate(state, Move.place(2, 9)).ok).toBe(true);
    const targets = NineMensMorrisRules.captureTargets(
      [...boardOf({ ...layout, 2: 'R' })],
      Cell.RED,
    );
    expect(targets.sort((a, b) => a - b)).toEqual([8, 9, 10]);
  });

  test('a mill against an empty board ends the turn without a capture', () => {
    const state = buildState({ layout: { 0: 'R', 1: 'R' }, toMove: Side.RED, hands: [7, 9] });
    expect(validate(state, Move.place(2)).ok).toBe(true);
    const variants = NineMensMorrisRules.legalMovesLanding(state, 2);
    expect(variants).toHaveLength(1);
    expect(variants[0].capture).toBe(NONE_CAPTURE);
    expect(validate(state, Move.place(2, 8)).issue).toBe(Issue.CAPTURE_TARGET);
  });

  test('a mill not through the landing point does not trigger a capture', () => {
    // Red already holds 16-17-18; placing at 5 completes nothing there.
    const state = buildState({
      layout: { 16: 'R', 17: 'R', 18: 'R', 8: 'G', 9: 'G', 10: 'G' },
      toMove: Side.RED,
      hands: [6, 6],
    });
    expect(validate(state, Move.place(5)).ok).toBe(true);
    expect(validate(state, Move.place(5, 8)).issue).toBe(Issue.CAPTURE_FORBIDDEN);
  });

  test('moving out of and back into a mill forms it anew', () => {
    // Red mills 0-1-2, moves 2 away (breaking), then returns.
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 2: 'R', 8: 'G' },
      toMove: Side.RED,
      hands: [0, 8],
    });
    const moveOut = validate(state, Move.step(2, 3));
    expect(moveOut.ok).toBe(true);
    const afterRed = NineMensMorrisRules.apply(state, Move.step(2, 3))!;
    expect(afterRed.result).toBe(GameResult.NONE);
    const afterGreen = NineMensMorrisRules.apply(afterRed, Move.place(10))!;
    expect(afterGreen.result).toBe(GameResult.NONE);
    const back = validate(afterGreen, Move.step(3, 2));
    expect(back.issue).toBe(Issue.CAPTURE_REQUIRED);
  });
});

describe('wins', () => {
  test('a side to move with fewer than three pieces and no hand loses', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 4: 'R', 6: 'R', 8: 'G', 12: 'G' },
      toMove: Side.GREEN,
      hands: [0, 0],
      ply: 40,
    });
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.RED_WIN);
  });

  test('an immobilised side loses even with four pieces', () => {
    // Green corners are sealed in by reds on every neighbour.
    const state = buildState({
      layout: {
        0: 'G', 2: 'G', 4: 'G', 6: 'G',
        1: 'R', 3: 'R', 5: 'R', 7: 'R',
        8: 'R', 10: 'R', 12: 'R', 14: 'R',
      },
      toMove: Side.GREEN,
      hands: [0, 0],
      ply: 60,
    });
    expect(NineMensMorrisRules.legalMoves(state)).toHaveLength(0);
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.RED_WIN);
  });

  test('starvation does not fire while the hand still holds pieces', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 4: 'R', 8: 'G' },
      toMove: Side.GREEN,
      hands: [0, 5],
      ply: 30,
    });
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.NONE);
  });

  test('a finished position is sticky', () => {
    const state = buildState({ result: GameResult.GREEN_WIN, hands: [0, 0] });
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.GREEN_WIN);
    expect(NineMensMorrisRules.legalMoves(state)).toHaveLength(0);
    expect(validate(state, Move.place(5)).issue).toBe(Issue.GAME_OVER);
  });
});

describe('draws', () => {
  test('threefold repetition draws', () => {
    const state = buildState({ hands: [4, 4], ply: 12 });
    const key = state.repetitionKey();
    state.history = [key, key, key];
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.DRAW);
  });

  test('twice is not yet a draw', () => {
    const state = buildState({ hands: [4, 4], ply: 12 });
    const key = state.repetitionKey();
    state.history = [key, key];
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.NONE);
  });

  test('fifty plies without a capture draw', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 4: 'R', 8: 'G', 12: 'G' },
      hands: [0, 0],
      since: PLIES_TO_DRAW - 1,
    });
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.NONE);
    state.pliesSinceCapture = PLIES_TO_DRAW;
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.DRAW);
  });

  test('a win is reported before a draw', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 8: 'G' },
      toMove: Side.GREEN,
      hands: [0, 0],
      since: PLIES_TO_DRAW + 10,
    });
    state.history = [state.repetitionKey(), state.repetitionKey(), state.repetitionKey()];
    expect(NineMensMorrisRules.evaluate(state)).toBe(GameResult.RED_WIN);
  });
});

describe('apply', () => {
  test('the input state is never mutated', () => {
    const state = GameState.initial();
    const before = JSON.stringify(state.serialize());
    NineMensMorrisRules.apply(state, Move.place(5));
    expect(JSON.stringify(state.serialize())).toBe(before);
  });

  test('a placement decrements the hand, advances ply and toggles the side', () => {
    const state = GameState.initial();
    const next = NineMensMorrisRules.apply(state, Move.place(16))!;
    expect(next.hands).toEqual([8, 9]);
    expect(next.board[16]).toBe(Cell.RED);
    expect(next.sideToMove).toBe(Side.GREEN);
    expect(next.ply).toBe(1);
    expect(next.pliesSinceCapture).toBe(1);
    expect(next.history).toHaveLength(2);
    expect(next.result).toBe(GameResult.NONE);
  });

  test('a capture resets the counter, otherwise it increments', () => {
    const state = buildState({
      layout: { 0: 'R', 1: 'R', 8: 'G', 10: 'G' },
      toMove: Side.RED,
      hands: [6, 7],
      since: 9,
    });
    const next = NineMensMorrisRules.apply(state, Move.place(2, 8))!;
    expect(next.board[8]).toBe(Cell.EMPTY);
    expect(next.pliesSinceCapture).toBe(0);
    expect(next.hands).toEqual([5, 7]);
    const plain = NineMensMorrisRules.apply(
      buildState({ hands: [6, 7], since: 9, layout: { 8: 'G' } }),
      Move.place(5),
    )!;
    expect(plain.pliesSinceCapture).toBe(10);
  });

  test('apply refuses an illegal move', () => {
    const state = GameState.initial();
    expect(NineMensMorrisRules.apply(state, Move.place(0, 1))).toBeNull();
    expect(NineMensMorrisRules.apply(state, Move.step(0, 1))).toBeNull();
    const absent: GameState | null = null;
    expect(NineMensMorrisRules.apply(absent, Move.place(0))).toBeNull();
  });

  test('the opening sequence plays out per the specification', () => {
    let state = GameState.initial();
    const play = (move: Move) => {
      state = NineMensMorrisRules.apply(state, move)!;
      expect(state).not.toBeNull();
    };
    play(Move.place(0));
    play(Move.place(8));
    play(Move.place(1));
    play(Move.place(10));
    expect(NineMensMorrisRules.legalMovesLanding(state, 2)).toHaveLength(2);
    play(Move.place(2, 8));
    expect(state.board[8]).toBe(Cell.EMPTY);
    expect(state.sideToMove).toBe(Side.GREEN);
    expect(state.hands).toEqual([6, 7]);
    expect(state.pliesSinceCapture).toBe(0);
    expect(state.ply).toBe(5);
  });
});

describe('serialization', () => {
  test('the initial position round-trips', () => {
    const state = GameState.initial();
    const raw = state.serialize();
    expect(raw.board).toBe(INITIAL_BOARD);
    expect(raw.board).toHaveLength(24);
    expect(raw.version).toBe(1);
    const back = GameState.deserialize(raw);
    expect(back).not.toBeNull();
    expect(back!.serialize()).toEqual(raw);
    expect(back!.repetitionKey()).toBe(state.repetitionKey());
  });

  test('a mid-game position round-trips including history', () => {
    const state = buildState({
      layout: { 0: 'R', 8: 'G', 1: 'R' },
      toMove: Side.GREEN,
      hands: [7, 8],
      ply: 3,
      since: 2,
    });
    const raw = state.serialize();
    expect(raw.to_move).toBe(Side.GREEN);
    expect(raw.hand_red).toBe(7);
    expect(raw.hand_green).toBe(8);
    const back = GameState.deserialize(JSON.parse(JSON.stringify(raw)))!;
    expect(back.serialize()).toEqual(raw);
    expect(back.history).toEqual(state.history);
  });

  test('corrupt payloads are rejected', () => {
    const good = GameState.initial().serialize();
    expect(GameState.deserialize(null)).toBeNull();
    expect(GameState.deserialize('nope')).toBeNull();
    expect(GameState.deserialize({ ...good, version: 2 })).toBeNull();
    expect(GameState.deserialize({ ...good, board: 'short' })).toBeNull();
    expect(GameState.deserialize({ ...good, board: `${good.board.slice(0, 23)}X` })).toBeNull();
    expect(GameState.deserialize({ ...good, to_move: 'blue' })).toBeNull();
    expect(GameState.deserialize({ ...good, hand_red: 10 })).toBeNull();
    expect(GameState.deserialize({ ...good, hand_green: -1 })).toBeNull();
    expect(GameState.deserialize({ ...good, ply: -1 })).toBeNull();
    expect(GameState.deserialize({ ...good, plies_since_capture: 1.5 })).toBeNull();
    expect(GameState.deserialize({ ...good, result: 'win' })).toBeNull();
    expect(GameState.deserialize({ ...good, history: [] })).toBeNull();
    expect(GameState.deserialize({ ...good, history: [1, 2] })).toBeNull();
  });
});

describe('wire moves and notation', () => {
  test('valid payloads parse', () => {
    const place = Move.fromWire({ kind: 'place', point: 17, capture: 22 })!;
    expect(place.kind).toBe('place');
    expect(place.point).toBe(17);
    expect(place.capture).toBe(22);
    const step = Move.fromWire({ kind: 'move', from: 9, to: 17 })!;
    expect(step.kind).toBe('move');
    expect(step.from).toBe(9);
    expect(step.to).toBe(17);
    expect(step.capture).toBe(NONE_CAPTURE);
    expect(Move.fromWire({ kind: 'move', from: 9, to: 17, capture: null })!.capture).toBe(
      NONE_CAPTURE,
    );
  });

  test('malformed payloads are rejected', () => {
    expect(Move.fromWire(null)).toBeNull();
    expect(Move.fromWire({})).toBeNull();
    expect(Move.fromWire({ kind: 'jump', point: 1 })).toBeNull();
    expect(Move.fromWire({ kind: 'place' })).toBeNull();
    expect(Move.fromWire({ kind: 'place', point: 1.5 })).toBeNull();
    expect(Move.fromWire({ kind: 'move', from: 1 })).toBeNull();
    expect(Move.fromWire({ kind: 'move', from: 1, to: 2, capture: 'x' })).toBeNull();
  });

  test('wire round-trips', () => {
    for (const move of [Move.place(5), Move.place(5, 11), Move.step(9, 17), Move.step(0, 1, 8)]) {
      expect(Move.fromWire(move.toWire())).toEqual(move);
    }
  });

  test('notation follows the star convention', () => {
    expect(NineMensMorrisRules.notation(Move.place(17))).toBe('P17');
    expect(NineMensMorrisRules.notation(Move.place(17, 22))).toBe('P17*22');
    expect(NineMensMorrisRules.notation(Move.step(9, 17))).toBe('9-17');
    expect(NineMensMorrisRules.notation(Move.step(9, 17, 3))).toBe('9-17*3');
  });

  test('legalNotations mirrors legalMoves', () => {
    const state = GameState.initial();
    const notations = legalNotations(state);
    expect(notations).toHaveLength(24);
    expect(notations[0]).toBe('P0');
    expect(notations).toEqual(NineMensMorrisRules.legalNotations(state));
  });
});

describe('state hash', () => {
  test('equal serializations hash equally and changes are visible', () => {
    const a = GameState.initial().serialize();
    const b = GameState.initial().serialize();
    expect(stateHash(a)).toBe(stateHash(b));
    expect(stateHash({ ...a, board: `${a.board.slice(0, 23)}R` })).not.toBe(stateHash(a));
    expect(stateHash({ ...a, ply: 1 })).not.toBe(stateHash(a));
    expect(stateHash({ ...a, hand_red: 8 })).not.toBe(stateHash(a));
    expect(stateHash({ ...a, to_move: Side.GREEN })).not.toBe(stateHash(a));
    expect(stateHash({ ...a, result: GameResult.DRAW })).not.toBe(stateHash(a));
    expect(stateHash(a)).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe('error messages', () => {
  test('every issue has a user-facing message except OK', () => {
    for (const issue of Object.values(Issue)) {
      if (typeof issue !== 'number') continue;
      if (issue === Issue.OK) {
        expect(errorText(issue)).toBe('');
      } else {
        expect(errorText(issue).length).toBeGreaterThan(10);
      }
    }
    expect(errorText(999 as Issue)).toBe('That move is not allowed.');
  });
});
