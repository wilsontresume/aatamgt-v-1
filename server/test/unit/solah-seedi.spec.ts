import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import {
  Cell,
  GameResult,
  GameState,
  INITIAL_BOARD,
  Issue,
  LINES,
  Move,
  PIECES_PER_SIDE,
  POINT_COUNT,
  SolahSeediRules,
  Side,
  errorText,
  stateHash,
  validate,
} from '../../src/solah-seedi';

/**
 * Server-side rules engine suite for Solah Seedi (16 Soldiers), built
 * against docs/solah_seedi_rules.md. Geometry is cross-checked against
 * the pixel-verified board diagram: 37 points, 20 polylines, 76
 * segments.
 */

function buildState(
  red: number[],
  green: number[],
  side: Side,
  ply: number,
  pliesSinceCapture = 0,
): GameState {
  const state = new GameState();
  for (const point of red) state.board[point] = Cell.RED;
  for (const point of green) state.board[point] = Cell.GREEN;
  state.sideToMove = side;
  state.ply = ply;
  state.pliesSinceCapture = pliesSinceCapture;
  return state;
}

/** Red 11 can jump green 16 onto 21 (line V0). */
const fixtureJump = (): GameState => buildState([11], [16, 30], Side.RED, 1);

/** Red 6 can chain 6→16→26 over greens 11 and 21 (line V0). */
const fixtureChain = (): GameState => buildState([6], [11, 21, 30], Side.RED, 3);

/** Red 28 can step or jump onto the bottom triangle (31 / 35). */
const fixtureBreakthrough = (): GameState => buildState([28], [32, 30], Side.RED, 5);

/** Red 8 can jump the last green 13 onto 18 (line VC). */
const fixtureLastCapture = (): GameState => buildState([8], [13], Side.RED, 7);

/** Green 16 is completely frozen: every neighbour and landing occupied. */
const fixtureImmobilised = (): GameState =>
  buildState(
    [17, 11, 21, 12, 22, 18, 20, 6, 26, 8, 28],
    [16],
    Side.GREEN,
    9,
  );

const notations = (moves: Move[]): string[] => moves.map((m) => SolahSeediRules.notation(m));

describe('Solah Seedi rules engine (deterministic server port)', () => {
  describe('topology', () => {
    it('matches the pixel-verified chart of the rules doc', () => {
      expect(LINES).toHaveLength(20);
      expect([...SolahSeediRules.neighbors(8)].sort((a, b) => a - b)).toEqual([3, 4, 5, 7, 9, 12, 13, 14]);
      expect([...SolahSeediRules.neighbors(31)].sort((a, b) => a - b)).toEqual([28, 32, 34]);
      expect([...SolahSeediRules.neighbors(0)].sort((a, b) => a - b)).toEqual([1, 3]);
      expect([...SolahSeediRules.neighbors(16)].sort((a, b) => a - b)).toEqual([11, 12, 17, 21, 22]);
      expect(SolahSeediRules.areAdjacent(0, 1)).toBe(true);
      expect(SolahSeediRules.areAdjacent(0, 3)).toBe(true);
      expect(SolahSeediRules.areAdjacent(0, 8)).toBe(false);
      expect(SolahSeediRules.areAdjacent(1, 8)).toBe(false);
      expect(SolahSeediRules.areAdjacent(6, 7)).toBe(true);
      expect(SolahSeediRules.areAdjacent(6, 8)).toBe(false);
      expect(SolahSeediRules.areAdjacent(6, 12)).toBe(true);
      expect(SolahSeediRules.areAdjacent(16, 20)).toBe(false);
      expect(SolahSeediRules.areAdjacent(31, 34)).toBe(true);
      expect(SolahSeediRules.areAdjacent(31, 21)).toBe(false);
      expect(SolahSeediRules.areAdjacent(1, 4)).toBe(true);
      expect(SolahSeediRules.areAdjacent(28, 32)).toBe(true);
      expect(SolahSeediRules.areAdjacent(22, 28)).toBe(true);
      expect(SolahSeediRules.areAdjacent(24, 28)).toBe(true);
      expect(SolahSeediRules.areAdjacent(20, 24)).toBe(true);
    });

    it('expands the polylines to exactly 76 segments', () => {
      let segments = 0;
      const seen = new Set<string>();
      for (const line of LINES) {
        for (let i = 0; i < line.length - 1; i++) {
          const a = line[i];
          const b = line[i + 1];
          const key = `${Math.min(a, b)},${Math.max(a, b)}`;
          expect(seen.has(key)).toBe(false);
          seen.add(key);
          segments++;
          expect(SolahSeediRules.areAdjacent(a, b)).toBe(true);
        }
      }
      expect(segments).toBe(76);
      let degreeSum = 0;
      for (let p = 0; p < POINT_COUNT; p++) degreeSum += SolahSeediRules.neighbors(p).length;
      expect(degreeSum).toBe(152);
    });

    it('resolves every jump through a unique middle point', () => {
      expect(SolahSeediRules.jumpMiddle(6, 8)).toBe(7);
      expect(SolahSeediRules.jumpMiddle(8, 6)).toBe(7);
      expect(SolahSeediRules.jumpMiddle(0, 8)).toBe(3);
      expect(SolahSeediRules.jumpMiddle(8, 20)).toBe(14);
      expect(SolahSeediRules.jumpMiddle(1, 8)).toBe(4);
      expect(SolahSeediRules.jumpMiddle(6, 16)).toBe(11);
      expect(SolahSeediRules.jumpMiddle(11, 21)).toBe(16);
      expect(SolahSeediRules.jumpMiddle(28, 35)).toBe(32);
      expect(SolahSeediRules.jumpMiddle(31, 33)).toBe(32);
      expect(SolahSeediRules.jumpMiddle(31, 35)).toBeNull();
      expect(SolahSeediRules.jumpMiddle(0, 14)).toBeNull();
      expect(SolahSeediRules.jumpMiddle(6, 7)).toBeNull();
      expect(SolahSeediRules.jumpMiddle(6, 10)).toBeNull();
      expect(SolahSeediRules.jumpMiddle(0, 5)).toBeNull();
      for (const line of LINES) {
        for (let i = 0; i < line.length - 2; i++) {
          expect(SolahSeediRules.jumpMiddle(line[i], line[i + 2])).toBe(line[i + 1]);
          expect(SolahSeediRules.jumpMiddle(line[i + 2], line[i])).toBe(line[i + 1]);
        }
      }
    });
  });

  describe('initial state', () => {
    it('is the published starting position', () => {
      const state = GameState.initial();
      expect(state.boardString()).toBe(INITIAL_BOARD);
      expect(state.sideToMove).toBe(Side.RED);
      expect(state.ply).toBe(0);
      expect(state.pliesSinceCapture).toBe(0);
      expect(state.result).toBe(GameResult.NONE);
      expect(state.countPieces(Cell.RED)).toBe(PIECES_PER_SIDE);
      expect(state.countPieces(Cell.GREEN)).toBe(PIECES_PER_SIDE);
      expect(state.pointsOf(Cell.RED)).toEqual([...Array(16).keys()]);
      expect(state.pointsOf(Cell.GREEN)).toEqual([...Array(16).keys()].map((i) => i + 21));
      expect(state.isEmpty(16)).toBe(true);
      expect(state.isEmpty(20)).toBe(true);
      expect(state.countsConsistent()).toBe(true);
      expect(state.isTerminal()).toBe(false);
    });

    it('offers exactly the 9 opening steps and no captures', () => {
      const state = GameState.initial();
      const moves = SolahSeediRules.legalMoves(state);
      expect(moves).toHaveLength(9);
      expect(notations(moves).sort()).toEqual(
        ['11-16', '12-16', '12-17', '12-18', '13-18', '14-18', '14-19', '14-20', '15-20'].sort(),
      );
      expect(moves.every((m) => m.path.length === 2)).toBe(true);
      expect(SolahSeediRules.legalMovesFrom(state, 0)).toHaveLength(0);
      expect(
        moves.every((move) => validate(state, move).ok),
      ).toBe(true);
    });
  });

  describe('steps', () => {
    it('moves a piece along one line and passes the turn', () => {
      const state = GameState.initial();
      const next = SolahSeediRules.apply(state, Move.step(11, 16))!;
      expect(next.board[11]).toBe(Cell.EMPTY);
      expect(next.board[16]).toBe(Cell.RED);
      expect(next.sideToMove).toBe(Side.GREEN);
      expect(next.ply).toBe(1);
      expect(next.pliesSinceCapture).toBe(1);
      expect(next.result).toBe(GameResult.NONE);
      expect(state.countsConsistent()).toBe(true);
    });

    it('documents the step issues', () => {
      const state = GameState.initial();
      expect(validate(state, Move.step(16, 17)).issue).toBe(Issue.EMPTY_ORIGIN);
      expect(validate(state, Move.step(11, 6)).issue).toBe(Issue.OCCUPIED);
      expect(validate(state, Move.step(11, 99)).issue).toBe(Issue.OUT_OF_RANGE);
      const greenTurn = SolahSeediRules.apply(state, Move.step(11, 16))!;
      expect(validate(greenTurn, Move.step(6, 7)).issue).toBe(Issue.NOT_YOUR_PIECE);
      expect(validate(state, Move.step(11, 16)).ok).toBe(true);
      expect(validate(state, Move.step(6, 10)).issue).toBe(Issue.JUMP_GEOMETRY);
      expect(validate(state, Move.fromPath([6, 7, 8])).issue).toBe(Issue.CHAIN_STEP);
    });
  });

  describe('captures', () => {
    it('jumps one enemy along a line and resets the draw counter', () => {
      const state = fixtureJump();
      const move = Move.fromPath([11, 21]);
      expect(validate(state, move).ok).toBe(true);
      const after = SolahSeediRules.apply(state, move)!;
      expect(after.board[11]).toBe(Cell.EMPTY);
      expect(after.board[16]).toBe(Cell.EMPTY);
      expect(after.board[21]).toBe(Cell.RED);
      expect(after.countPieces(Cell.GREEN)).toBe(1);
      expect(after.pliesSinceCapture).toBe(0);
      expect(after.ply).toBe(2);
      expect(after.sideToMove).toBe(Side.GREEN);
      expect(after.result).toBe(GameResult.NONE);
      expect(after.countsConsistent()).toBe(true);
    });

    it('keeps captures optional: steps and jumps coexist', () => {
      const state = fixtureJump();
      const fromOrigin = SolahSeediRules.legalMovesFrom(state, 11);
      // 11-16 is a step onto the green (illegal); the jump is 11-21 over 16.
      expect(notations(fromOrigin).sort()).toEqual(['11-12', '11-21*', '11-6'].sort());
      expect(fromOrigin.some((m) => SolahSeediRules.notation(m).endsWith('*'))).toBe(true);
      expect(fromOrigin.some((m) => !SolahSeediRules.notation(m).endsWith('*'))).toBe(true);
    });

    it('documents the jump issues', () => {
      const state = fixtureJump();
      expect(validate(state, Move.fromPath([11, 16])).issue).toBe(Issue.OCCUPIED);
      expect(validate(state, Move.fromPath([11, 21, 22])).issue).toBe(Issue.CHAIN_STEP);
      expect(validate(state, Move.fromPath([11, 21])).ok).toBe(true);
      const landingBlocked = buildState([11], [16, 21, 30], Side.RED, 1);
      expect(validate(landingBlocked, Move.fromPath([11, 21])).issue).toBe(Issue.JUMP_LANDING);
      expect(validate(GameState.initial(), Move.fromPath([11, 21])).issue).toBe(Issue.JUMP_NOT_ENEMY);
      expect(validate(state, Move.fromPath([11, 20])).issue).toBe(Issue.JUMP_GEOMETRY);
      expect(errorText(Issue.JUMP_LANDING)).toContain('empty');
    });

    it('ends the game the moment the last enemy is captured', () => {
      const state = fixtureLastCapture();
      expect(state.countPieces(Cell.GREEN)).toBe(1);
      expect(SolahSeediRules.evaluate(state)).toBe(GameResult.NONE);
      const win = SolahSeediRules.apply(state, Move.fromPath([8, 18]))!;
      expect(win.result).toBe(GameResult.RED_WIN);
      expect(win.countPieces(Cell.GREEN)).toBe(0);
      expect(win.countsConsistent()).toBe(true);
      expect(SolahSeediRules.legalMoves(win)).toHaveLength(0);
      expect(validate(win, Move.step(8, 7)).issue).toBe(Issue.GAME_OVER);
      expect(SolahSeediRules.apply(win, Move.step(8, 7))).toBeNull();
      expect(errorText(Issue.GAME_OVER)).toContain('game is over');
    });
  });

  describe('chains', () => {
    it('enumerates every prefix so the chain may stop after any hop', () => {
      const state = fixtureChain();
      const fromOrigin = SolahSeediRules.legalMovesFrom(state, 6);
      expect(notations(fromOrigin).sort()).toEqual(['6-12', '6-16*', '6-16-26*', '6-7'].sort());
      expect(validate(state, Move.fromPath([6, 16])).ok).toBe(true);
      expect(validate(state, Move.fromPath([6, 16, 26])).ok).toBe(true);
      const after = SolahSeediRules.apply(state, Move.fromPath([6, 16, 26]))!;
      expect(after.board[6]).toBe(Cell.EMPTY);
      expect(after.board[11]).toBe(Cell.EMPTY);
      expect(after.board[16]).toBe(Cell.EMPTY);
      expect(after.board[21]).toBe(Cell.EMPTY);
      expect(after.board[26]).toBe(Cell.RED);
      expect(after.countPieces(Cell.GREEN)).toBe(1);
      expect(after.pliesSinceCapture).toBe(0);
      expect(after.ply).toBe(4);
      expect(after.sideToMove).toBe(Side.GREEN);
      expect(after.result).toBe(GameResult.NONE);
    });

    it('verifies occupancy hop-by-hop on a scratch board', () => {
      const state = fixtureChain();
      // Landing of hop 1 occupied: the chain cannot start there.
      const blocked = fixtureChain();
      blocked.board[16] = Cell.GREEN;
      expect(validate(blocked, Move.fromPath([6, 16, 26])).issue).toBe(Issue.JUMP_LANDING);
      expect(validate(blocked, Move.fromPath([6, 16])).issue).toBe(Issue.JUMP_LANDING);
      // Re-entering the vacated origin is legal (it is empty after hop 1).
      expect(validate(state, Move.fromPath([6, 16, 6])).issue).toBe(Issue.JUMP_NOT_ENEMY); // middle 11 already removed
      // Stepping inside a chain is rejected.
      expect(validate(state, Move.fromPath([6, 7, 8])).issue).toBe(Issue.CHAIN_STEP);
    });

    it('never extends a chain past a winning hop', () => {
      const state = fixtureBreakthrough();
      const fromOrigin = SolahSeediRules.legalMovesFrom(state, 28);
      expect(notations(fromOrigin)).toContain('28-31');
      expect(notations(fromOrigin)).toContain('28-35*');
      const overlong = fromOrigin.filter((m) => m.path.length > 2 && m.path[1] === 35);
      expect(overlong).toHaveLength(0);
      // …and rejects one if a client submits it anyway.
      const cont = Move.fromPath([28, 35, 28]);
      expect(validate(state, cont).issue).toBe(Issue.PATH_AFTER_WIN);
      expect(errorText(Issue.PATH_AFTER_WIN)).toContain('earlier hop');
    });
  });

  describe('outcomes', () => {
    it('wins by landing on the opponent triangle (step or jump)', () => {
      const state = fixtureBreakthrough();
      expect(SolahSeediRules.evaluate(state)).toBe(GameResult.NONE);
      const byStep = SolahSeediRules.apply(state, Move.step(28, 31))!;
      expect(byStep.result).toBe(GameResult.RED_WIN);
      expect(byStep.countsConsistent()).toBe(true);
      const byJump = SolahSeediRules.apply(state, Move.fromPath([28, 35]))!;
      expect(byJump.result).toBe(GameResult.RED_WIN);
      const greenTarget = buildState([8], [33, 0], Side.GREEN, 3);
      greenTarget.board[0] = Cell.EMPTY; // keep the position open
      const greenStep = SolahSeediRules.apply(
        buildState([8], [34, 30], Side.GREEN, 3),
        Move.step(34, 35),
      );
      expect(greenStep).not.toBeNull(); // 35 is green's own triangle: no win for green there
      void greenTarget;
    });

    it('wins for red when green is totally immobilised', () => {
      const state = fixtureImmobilised();
      expect(state.countsConsistent()).toBe(true);
      expect(SolahSeediRules.legalMoves(state)).toHaveLength(0);
      expect(SolahSeediRules.evaluate(state)).toBe(GameResult.RED_WIN);
    });

    it('draws after 60 plies without a capture and keeps the draw stable', () => {
      const before = buildState([8], [13], Side.RED, 59, 59);
      expect(SolahSeediRules.evaluate(before)).toBe(GameResult.NONE);
      const after = SolahSeediRules.apply(before, Move.step(8, 7))!;
      expect(after.ply).toBe(60);
      expect(after.pliesSinceCapture).toBe(60);
      expect(after.result).toBe(GameResult.DRAW);
      expect(SolahSeediRules.evaluate(after)).toBe(GameResult.DRAW);
      // A capture at ply 59 resets the counter: no draw.
      const capture = buildState([8], [13], Side.RED, 59, 59);
      const busy = SolahSeediRules.apply(capture, Move.fromPath([8, 18]))!;
      expect(busy.result).toBe(GameResult.RED_WIN); // last green: capture-all wins first
      const notLast = buildState([11], [16, 30], Side.RED, 59, 59);
      const continued = SolahSeediRules.apply(notLast, Move.fromPath([11, 21]))!;
      expect(continued.pliesSinceCapture).toBe(0);
      expect(continued.result).toBe(GameResult.NONE);
    });

    it('evaluates wins before the draw and never flips a decided result', () => {
      const over = SolahSeediRules.apply(fixtureLastCapture(), Move.fromPath([8, 18]))!;
      over.ply = 99;
      over.pliesSinceCapture = 99;
      expect(SolahSeediRules.evaluate(over)).toBe(GameResult.RED_WIN);
    });
  });

  describe('serialization', () => {
    it('matches the published contract and round-trips', () => {
      const initial = GameState.initial();
      expect(initial.serialize()).toEqual({
        version: 1,
        board: INITIAL_BOARD,
        side_to_move: 'red',
        ply: 0,
        plies_since_capture: 0,
        result: 'none',
      });
      const restored = GameState.deserialize(initial.serialize());
      expect(restored).not.toBeNull();
      expect(restored!.serialize()).toEqual(initial.serialize());
      expect(notations(SolahSeediRules.legalMoves(restored!))).toEqual(
        notations(SolahSeediRules.legalMoves(initial)),
      );

      const fixture = fixtureImmobilised();
      const roundTrip = GameState.deserialize(fixture.serialize());
      expect(roundTrip).not.toBeNull();
      expect(roundTrip!.serialize()).toEqual(fixture.serialize());
      expect(notations(SolahSeediRules.legalMoves(roundTrip!))).toEqual(
        notations(SolahSeediRules.legalMoves(fixture)),
      );
    });

    it('rejects malformed payloads', () => {
      const base = GameState.initial().serialize();
      expect(GameState.deserialize(null)).toBeNull();
      expect(GameState.deserialize({ ...base, board: 'RRR' })).toBeNull();
      expect(GameState.deserialize({ ...base, side_to_move: 'birds' })).toBeNull();
      expect(GameState.deserialize({ ...base, result: 'drawish' })).toBeNull();
      expect(GameState.deserialize({ ...base, version: 99 })).toBeNull();
      expect(GameState.deserialize({ ...base, ply: -1 })).toBeNull();
      expect(GameState.deserialize({ ...base, plies_since_capture: -1 })).toBeNull();
      expect(GameState.deserialize({ ...base, plies_since_capture: 5 })).toBeNull();
      expect(GameState.deserialize({ ...base, board: 'x' + base.board.slice(1) })).toBeNull();
      // 17 reds breaks conservation.
      expect(GameState.deserialize({ ...base, board: 'R'.repeat(17) + '.'.repeat(5) + 'G'.repeat(15) })).toBeNull();
      // A zeroed side must have a decided result.
      expect(GameState.deserialize({ ...base, board: '.'.repeat(37) })).toBeNull();
      expect(
        GameState.deserialize({ ...base, board: 'G' + '.'.repeat(16) + 'R'.repeat(20) }),
      ).toBeNull();
      // Green on the top triangle while the game is open is impossible.
      const infiltrated = GameState.initial();
      infiltrated.board[16] = Cell.EMPTY;
      infiltrated.board[2] = Cell.GREEN;
      infiltrated.board[30] = Cell.RED;
      expect(GameState.deserialize(infiltrated.serialize())).toBeNull();
      // …but a decided game may hold pieces anywhere sensible.
      const won = buildState([28], [32, 30], Side.RED, 9);
      won.result = GameResult.RED_WIN;
      expect(GameState.deserialize(won.serialize())).not.toBeNull();
      const noReds = buildState([], [30], Side.RED, 9);
      noReds.result = GameResult.GREEN_WIN;
      expect(GameState.deserialize(noReds.serialize())).not.toBeNull();
      const noRedsNone = buildState([], [30], Side.RED, 9);
      expect(GameState.deserialize(noRedsNone.serialize())).toBeNull();
    });

    it('uses the published move notation and wire shape', () => {
      expect(SolahSeediRules.notation(Move.step(6, 7))).toBe('6-7');
      expect(SolahSeediRules.notation(Move.fromPath([6, 16]))).toBe('6-16*');
      expect(SolahSeediRules.notation(Move.fromPath([6, 16, 26]))).toBe('6-16-26*');
      const move = Move.fromPath([6, 16, 26]);
      const restored = Move.fromWire(move.toJSON());
      expect(restored).not.toBeNull();
      expect(restored!.equals(move)).toBe(true);
      expect(Move.fromWire({ path: [6] })).toBeNull();
      expect(Move.fromWire({ path: '6-7' })).toBeNull();
      expect(Move.fromWire({ path: [6, 7.5] })).toBeNull();
      expect(Move.fromWire({ path: [...Array(17).keys()] })).toBeNull();
      expect(Move.fromWire(null)).toBeNull();
      expect(Move.fromWire({})).toBeNull();
    });

    it('hashes states canonically', () => {
      const a = stateHash(GameState.initial().serialize());
      const b = stateHash(GameState.initial().serialize());
      expect(a).toBe(b);
      expect(a).toHaveLength(64);
      const moved = SolahSeediRules.apply(GameState.initial(), Move.step(11, 16))!;
      expect(stateHash(moved.serialize())).not.toBe(a);
    });
  });

  describe('purity and determinism', () => {
    it('never mutates inputs and always agrees with the validator', () => {
      const state = fixtureChain();
      const snapshot = JSON.stringify(state.serialize());
      const legal = SolahSeediRules.legalMoves(state);
      const applied = SolahSeediRules.apply(state, legal[0]);
      expect(applied).not.toBeNull();
      expect(JSON.stringify(state.serialize())).toBe(snapshot);
      expect(notations(SolahSeediRules.legalMoves(state))).toEqual(notations(legal));
      expect(legal.every((move) => validate(state, move).ok)).toBe(true);
      expect(
        SolahSeediRules.legalMoves(GameState.initial()).every((move) =>
          validate(GameState.initial(), move).ok,
        ),
      ).toBe(true);
      expect(SolahSeediRules.apply(state, Move.fromPath([6, 10]))).toBeNull();
    });
  });

  describe('engine isolation', () => {
    it('contains no I/O, UI or environment concerns', () => {
      const dir = resolve(__dirname, '../../src/solah-seedi');
      const files = [
        'solah-seedi.move.ts',
        'solah-seedi.state.ts',
        'solah-seedi.validator.ts',
        'solah-seedi.rules.ts',
        'index.ts',
      ];
      const forbidden = ['node:fs', 'node:http', 'node:net', 'user://', 'Control', 'process.env'];
      for (const file of files) {
        const text = readFileSync(resolve(dir, file), 'utf8');
        for (const token of forbidden) {
          expect(text.includes(token)).toBe(false);
        }
      }
    });
  });
});
