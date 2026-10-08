# Solah Seedi / 16 Soldiers — Rule Specification (Phase 9)

This is the exact ruleset Phase 9 implements. It is fixed before coding; the
engine implements only what is written here.

## 1. Sources and how conflicts were resolved

| Rule | Sources consulted | Chosen |
|---|---|---|
| Board: 37 points = alquerque 5×5 lattice (25) + two triangles of 6 points on opposite edges | Wikipedia "Sixteen Soldiers"; alignitgames (25+6+6 = 37, rows 1/2 and 8/9 empty at start); solahseedi.com board page; cyningstan (no diagram) | 37 points; exact geometry in §2, pixel-verified against the Wikimedia "Sholo guti" board diagram (all 76 segments present, all tested crossings/absent links confirmed absent) |
| Start: 16 pieces per side = own triangle (6) + two nearest lattice rows (5+5); middle lattice row empty | Wikimedia diagram (shows exactly this position); alignitgames; solahseedi.com | as stated; **Red** = top side, **Green** = bottom side; **Red moves first** |
| Simple move: one piece to an adjacent empty point | Wikipedia/Parker (alquerque-family, no direction restriction); rollthedice.in forbids backward moves | **all directions legal** (backward included); rollthedice.in's no-backward rule is an excluded regional variant |
| Capture: jump one adjacent enemy onto the empty point immediately beyond, on the same straight line; chain captures | Wikipedia ("may" continue / may stop); Parker (captures optional); cyningstan (compulsory); alignitgames | **captures are optional**; chains allowed, may stop after any hop; direction may change between hops; cyningstan's compulsory-capture rule is an excluded variant |
| Win | Wikipedia/Parker/cyningstan/arcadiagames: capture all 16; solahseedi.com: reach the opponent's triangle | **both adopted**: capture-all OR move any piece onto the opponent's triangle (see §5); the stricter "outermost row only" reading is a documented variant, not implemented |
| Draw | **no source defines a draw rule** | **our defined rule**: 60 consecutive plies with no capture |
| Not implemented (excluded variants) | rollthedice.in (no backward moves, revive-soldier variant); cyningstan (compulsory capture); 18-piece/two-per-point forms; boards with more than two triangles | explicit non-goals |

## 2. Board

37 numbered points:

```
  0    1    2            top triangle (outer row)
  3    4    5            top triangle (inner row)
  6    7    8    9   10  lattice row 0
 11   12   13   14   15  lattice row 1
 16   17   18   19   20  lattice row 2  (middle, starts empty)
 21   22   23   24   25  lattice row 3
 26   27   28   29   30  lattice row 4
 31   32   33            bottom triangle (inner row)
 34   35   36            bottom triangle (outer row)
```

Lines are maximal straight polylines (ordered point sequences). A quiet move
goes from a point to the **next point on a line**. A jump uses **three
consecutive points of one line**.

| id | line |
|---|---|
| H0 | 6–7–8–9–10 |
| H1 | 11–12–13–14–15 |
| H2 | 16–17–18–19–20 |
| H3 | 21–22–23–24–25 |
| H4 | 26–27–28–29–30 |
| T0 | 0–1–2 |
| T1 | 3–4–5 |
| B1 | 31–32–33 |
| B0 | 34–35–36 |
| V0 | 6–11–16–21–26 |
| V1 | 7–12–17–22–27 |
| VC | 1–4–8–13–18–23–28–32–35 |
| V3 | 9–14–19–24–29 |
| V4 | 10–15–20–25–30 |
| DR1 | 0–3–8–14–20 |
| DR2 | 6–12–18–24–30 |
| DR3 | 20–24–28–31–34 |
| DL1 | 2–5–8–12–16 |
| DL2 | 10–14–18–22–26 |
| DL3 | 16–22–28–33–36 |

The 20 polylines expand to exactly **76 segments** (40 orthogonal, 16
lattice diagonals, 20 triangle edges). Lattice diagonals follow the
alquerque checkerboard: cell (c,r) of the lattice carries `\` when (c+r) is
even and `/` when odd, so lattice points with even (c+r) are four-way
diagonal junctions and odd points carry no lattice diagonal. The triangles
have **no internal crossing diagonals**: each connects to the rest of the
board only through the centre point of its own lattice row (point 8 for the
top, point 28 for the bottom) and through its own two slant chains (DR1/DL1
and DR3/DL3).

Derived adjacency (consecutive pairs): point 8 is adjacent to 4, 7, 9, 13
(orthogonal/centre vertical), 3, 14 (DR1), 5, 12 (DL1) — **not** to 1 (4
stands between), **not** to 6 or 10 (7 and 9 stand between), **not** to 16,
17, 19 or 20; point 31 is adjacent to 32, 28, 34 (**not** to 21 or 27).

For every legal jump the middle point is uniquely determined by its
endpoints (the middle of a three-consecutive run lies strictly between them
on one straight line), so a jump can be written by its landings alone.

## 3. Pieces and starting position

- **Red: 16 pieces on points 0–15** (top triangle + lattice rows 0–1).
- **Green: 16 pieces on points 21–36** (lattice rows 3–4 + bottom triangle).
- **Points 16–20 (middle row) empty.** Exactly 5 empty points at start.
- **Red moves first.** Side alternates strictly every ply; no passing.
- Pieces are never added after start; a jumped piece is removed permanently.

## 4. Turn system and legal movement

Exactly one of the side-to-move's pieces does one of:

### 4.1 Step
Move to an **adjacent empty point** (adjacency per §2, any direction —
forward, sideways and backward are all legal).

### 4.2 Jump (capture)
Jump over **exactly one adjacent enemy piece** onto the point **immediately
beyond** on the **same polyline** (three consecutive points of one line, in
either direction); landing point must be empty.
- May not jump a own piece, may not jump two pieces, may not turn a corner
  mid-jump (the three points must belong to one line).
- The jumped piece is removed immediately.

### 4.3 Chain capture
- After a jump, if the **same piece** can jump again from its landing point,
  the player **may** continue (each hop removes its jumped piece).
- The player **may stop after any hop** (captures are optional end-to-end:
  if a step and/or any jump exists, the player picks freely).
- Direction **may change** between hops; hops may be on different polylines.
- A chain is still **one ply**; a different piece cannot move mid-chain.
- Wins are evaluated **after every hop** (§5): a hop that wins ends the move
  immediately, whatever longer path was intended.

### 4.4 Notation and move wire form
Step `6-7`, single jump `6-18`, chain `6-18-30` (path = start point +
landing points); `*` marks a move containing at least one capture:
`6-7`, `6-18*`, `6-18-30*`.

Wire/JSON form: `{ "path": [6, 18, 30] }`.
- `len(path) == 2` and endpoints adjacent → step (destination must be empty).
- `len(path) >= 2`, every consecutive pair a legal jump → chain (each middle
  enemy, each landing empty, all hops use the same piece).
- `len(path) == 1`, empty or repeated points, wrong side's piece → rejected.

## 5. Outcome conditions

Evaluated in this order (wins take precedence over the draw):

1. **RED_WIN** — green pieces on board `== 0` (checked the moment the last
   green piece is jumped). **GREEN_WIN** — red pieces `== 0`.
2. **RED_WIN** — a red piece just landed (step or hop) on **any point of the
   bottom triangle (31–36)**. **GREEN_WIN** — a green piece just landed on
   **any point of the top triangle (0–5)**. *(Sources calling for only the
   outermost row are a stricter variant — see §1.)*
3. **Opponent wins** — at the start of a turn, the side to move has **no
   legal step and no legal jump for any of its pieces** (total
   immobilisation; no passing exists).
4. **DRAW** — `plies_since_capture >= 60` and no winner above.
   `plies_since_capture` increments each ply without a capture and resets to
   0 on any capture.

Conditions 1–2 fire after the move (or chain hop) that causes them;
condition 3 is evaluated when a turn begins; condition 4 after each
completed ply. Total pieces strictly decrease with every capture, so the
game is finite.

## 6. Undo

**Allowed.** The game is deterministic, perfect-information and has no
clocks, randomness or hidden state, so restoring a previous snapshot
(including `ply` and `plies_since_capture`) reproduces a legal earlier
position exactly. Undo is available from any ply (including from a terminal
position, which clears the result) down to the start position.

## 7. Restart

Any time, behind a confirmation dialog; resets to §3 and clears the saved
game.

## 8. Game state serialization

`SolahSeediGameState.serialize() -> Dictionary` (JSON-safe):

```
{ "version": 1,
  "board": "RRRRRRRRRRRRRRRR.....GGGGGGGGGGGGGGGG",  # 37 chars: R / G / .
  "side_to_move": "red" | "green",
  "ply": int >= 0,
  "plies_since_capture": int >= 0,
  "result": "none" | "red_win" | "green_win" | "draw" }
```

Initial `board` is exactly the string above (16 R, 5 dots, 16 G).

`deserialize()` rejects malformed data:
- length != 37, unknown symbols, unknown side/result;
- `ply < 0`, `plies_since_capture < 0` or `> ply`;
- more than 16 pieces of either colour (conservation: pieces only leave);
- `G == 0` but result != `red_win`; `R == 0` but result != `green_win`;
- result `none`/`draw` with `R == 0` or `G == 0`;
- result `red_win` with `R == 0`, or `green_win` with `G == 0`.

The screen persists the current game with `serialize()` after every move
and restores it with `deserialize()` on open.

## 9. Scope (Phase 9)

- **Game-specific only**: rules engine, board/piece rendering, local
  hot-seat screen, AI opponent, and this game's online match flow.
- **Reuses the common platform unchanged**: authentication, wallet/coins,
  rewards, matchmaking, sessions, profile, analytics, transport. Nothing is
  duplicated or forked for this game.
- **Server-authoritative online play**, identical architecture to Aadu
  Puli: the server owns state (`gameKey = 'solah-seedi'`), validates status →
  participant → turn → wire move → these rules in order, bumps
  `stateVersion`, hashes state, runs the turn clock, and records results
  with the existing reasons (`RULES|RESIGN|TIMEOUT|DISCONNECT`). The client
  never computes authority, only legality for hints/highlights.
- **Offline**: hot-seat and AI work with no server (mirroring Aadu Puli
  phases 4–5); the AI searches the same rules engine.
- **Architecture**: engine (`SolahSeediGameState`, `SolahSeediRules`,
  `SolahSeediMove`, `SolahSeediValidator`) is independent of any UI. The UI
  only renders state and submits requested moves; it never computes
  legality itself.

## Appendix A. Point coordinates (for rendering)

Normalised (x, y) in [0,1] from the reference diagram (643×1200; pixel
cells are square — lattice pitch ≈ 0.2135 × width ≈ 0.1145 × height):

| pt | x | y | pt | x | y | pt | x | y |
|---|---|---|---|---|---|---|---|---|
| 0 | 0.072 | 0.040 | 13 | 0.499 | 0.385 | 26 | 0.073 | 0.728 |
| 1 | 0.499 | 0.040 | 14 | 0.714 | 0.385 | 27 | 0.285 | 0.728 |
| 2 | 0.928 | 0.040 | 15 | 0.928 | 0.385 | 28 | 0.499 | 0.728 |
| 3 | 0.267 | 0.145 | 16 | 0.073 | 0.497 | 29 | 0.714 | 0.728 |
| 4 | 0.499 | 0.145 | 17 | 0.285 | 0.497 | 30 | 0.928 | 0.728 |
| 5 | 0.734 | 0.145 | 18 | 0.499 | 0.497 | 31 | 0.267 | 0.854 |
| 6 | 0.073 | 0.270 | 19 | 0.714 | 0.497 | 32 | 0.501 | 0.854 |
| 7 | 0.285 | 0.270 | 20 | 0.928 | 0.497 | 33 | 0.734 | 0.854 |
| 8 | 0.499 | 0.270 | 21 | 0.073 | 0.613 | 34 | 0.073 | 0.959 |
| 9 | 0.714 | 0.270 | 22 | 0.285 | 0.613 | 35 | 0.499 | 0.959 |
| 10 | 0.928 | 0.270 | 23 | 0.499 | 0.613 | 36 | 0.928 | 0.959 |
| 11 | 0.073 | 0.385 | 24 | 0.714 | 0.613 | | | |
| 12 | 0.285 | 0.385 | 25 | 0.928 | 0.613 | | | |

Note: triangle inner-row points (3, 5, 31, 33) sit slightly outboard of
lattice columns 1 and 3, matching the reference diagram.
