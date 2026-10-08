# Nine Men's Morris — Rule Specification (Phase 10)

## §1 Overview and scope

Nine Men's Morris is a 2-player mill game on a 24-point board. Each side
starts with nine pieces and plays in three phases: **placement**
(alternatingly putting pieces onto empty points), **movement** (stepping a
piece to an adjacent empty point) and **flying** (a player reduced to
exactly three pieces may move to any empty point). Forming a *mill* —
three of one side's pieces in a row on one of the board's sixteen mill
lines — obliges that player to remove one enemy piece.

This document is the single source of truth for the rules engine. The
TypeScript server engine (`server/src/nine-mens-morris/`) and the Godot
client port (`src/games/nine_mens_morris/`) implement it exactly; every
value below (numbering, mill lists, draw limits, wire keys) appears in
both ports unchanged. Authentication, wallets, turn clocks, presence,
matchmaking, rematch and reconnection are the shared AATAMGT platform
layer — this spec covers game logic only.

Sides are named **`red`** and **`green`** (wire keys), seat 0 is `red`
and moves first, seat 1 is `green` — the same seat convention as Solah
Seedi.

## §2 Board and point numbering

The board is drawn on a 7×7 grid of coordinates `(col, row)`, each
`0..6`. There are **24 points**: the corners and edge midpoints of three
concentric squares. The exact grid coordinate of every point:

| Point | Coord | Point | Coord | Point | Coord | Point | Coord |
|------:|:-----:|------:|:-----:|------:|:-----:|------:|:-----:|
| 0 | (0,0) | 1 | (3,0) | 2 | (6,0) | 3 | (6,3) |
| 4 | (6,6) | 5 | (3,6) | 6 | (0,6) | 7 | (0,3) |
| 8 | (1,1) | 9 | (3,1) | 10 | (5,1) | 11 | (5,3) |
| 12 | (5,5) | 13 | (3,5) | 14 | (1,5) | 15 | (1,3) |
| 16 | (2,2) | 17 | (3,2) | 18 | (4,2) | 19 | (4,3) |
| 20 | (4,4) | 21 | (3,4) | 22 | (2,4) | 23 | (2,3) |

Points 0–7 are the outer square (clockwise from top-left), 8–15 the
middle square, 16–23 the inner square; each square numbers clockwise
from its top-left corner, midpoints between corners. `(3,3)` — the board
centre — is **not** a point.

```
Rows of the 7×7 grid (y = row, points left to right; '.' = grid
coordinate with no point, except the empty centre at (3,3)):

y=0:  0 ------- 1 ------- 2              outer top
y=1:  .   8 ------- 9 ------- 10   .     middle top
y=2:  .   .   16 ------ 17 ------ 18 .   inner top
y=3:  7   15   23       ·       19  11   3
y=4:  .   .   22 ------ 21 ------ 20 .   inner bottom
y=5:  .   14 ------- 13 ------- 12   .   middle bottom
y=6:  6 ------- 5 ------- 4              outer bottom

Columns (x, top to bottom):
  x=0: 0, 7, 6        x=1: 8, 15, 14      x=2: 16, 23, 22
  x=3: 1, 9, 17, [centre], 21, 13, 5
  x=4: 18, 19, 20     x=5: 10, 11, 12     x=6: 2, 3, 4
```

**Adjacency — 32 edges** (each usable in both directions):

- Outer square (8): `0-1, 1-2, 2-3, 3-4, 4-5, 5-6, 6-7, 7-0`
- Middle square (8): `8-9, 9-10, 10-11, 11-12, 12-13, 13-14, 14-15, 15-8`
- Inner square (8): `16-17, 17-18, 18-19, 19-20, 20-21, 21-22, 22-23, 23-16`
- Radial arms (8): `1-9, 9-17, 3-11, 11-19, 5-13, 13-21, 7-15, 15-23`

## §3 Setup

- The board starts empty; every point is free.
- Each side has a **hand of 9 pieces** (`hand_red = 9`, `hand_green = 9`)
  and 0 pieces on the board.
- `red` (seat 0) moves first. `ply = 0`, `plies_since_capture = 0`,
  `result = "none"`, repetition history holds the initial position once.

## §4 Phases

A player's phase is derived, never stored:

1. **Placement** — while the player's hand is non-empty, the only legal
   action is to put one piece from hand onto an **empty** point.
2. **Movement** — hand empty and 4 or more pieces on the board: move one
   of the player's pieces along a single **edge** to an empty point.
3. **Flying** — hand empty and **exactly 3** pieces on the board: move
   one of the player's pieces to **any** empty point.

The two sides may be in different phases at the same time (one still
placing, the other already moving). Fewer than three pieces on the board
is covered by §7 (loss), never by a playable phase.

## §5 Mills

A **mill** is three pieces of one side occupying, in any order, the three
points of one of these **16 lines**:

| Kind | Mills (point triples) |
|:----:|:----------------------|
| Outer (4) | `0-1-2`, `2-3-4`, `4-5-6`, `6-7-0` |
| Middle (4) | `8-9-10`, `10-11-12`, `12-13-14`, `14-15-8` |
| Inner (4) | `16-17-18`, `18-19-20`, `20-21-22`, `22-23-16` |
| Radial (4) | `1-9-17`, `3-11-19`, `5-13-21`, `7-15-23` |

A piece is **in a mill** when it stands on a mill of its own side. Mills
are evaluated on the board **after** the placement or movement, before
any capture.

## §6 Capture

- If the just-completed placement or move **created at least one new
  mill** for the mover, the same turn continues with a **mandatory
  capture**: remove one of the opponent's pieces from the board.
- **Exception 1 — no target:** if the opponent has no piece on the board
  (possible only during the opening placements), the turn simply ends
  without a capture.
- **Exception 2 — pieces in mills:** a piece that is *in a mill* cannot
  be captured, **unless every** opponent piece on the board is in a mill;
  then any opponent piece may be captured.
- A mill must be *newly formed*: opening a mill by moving one piece out
  and back forms it again and is capture-worthy (repetition draws, §8,
  police endless shuffling; there is no additional recapture ban).
- The capture is part of the same turn: one wire move carries both the
  placement/movement and the chosen capture point (§10). A turn in which
  a mill was formed is never legal without its capture (except
  Exception 1).

## §7 Win and loss

Evaluated after every **completed** turn (placement, or movement plus any
forced capture), against the player who is **to move next**:

1. **Piece starvation** — that player's hand is empty and they have
   **fewer than 3 pieces** on the board → the mover wins.
2. **Immobilisation** — that player's hand is empty and they have **no
   legal action** for their phase (no empty point to place onto, or no
   legal step/fly) → the mover wins.
3. A player reduced to exactly three pieces regains no placement turns:
   hand empty ends placement permanently (hands only decrease).

The game is never won during placement by starvation: the placing player
still holds pieces in hand by definition. `result` is `"red_win"`,
`"green_win"` or `"draw"` (§8) and is final.

## §8 Draw rules

A position is **drawn** when either condition holds (evaluated after
every completed turn, first match wins):

1. **Threefold repetition** — any position occurs for the **third**
   time. The repetition key is:

   ```
   board(24) | to_move | hand_red | hand_green
   ```

   using the serialized board string (§9), wire side keys, and integer
   hands. The engine stores the ordered list of keys after each
   completed turn (initial position included) and counts occurrences of
   the just-reached key; a count of 3 → draw. Moves that re-form mills
   are legal (§6), so perpetual mill-threat loops end here.
2. **Fifty-ply no-capture limit** — `plies_since_capture >= 50`
   (fifty half-moves without any capture, whatever the phase). It resets
   to 0 on every capture, starts at 0.

## §9 Serialization

Stored position (`user://` save on the client, match row on the server),
JSON object, unknown keys ignored on load, `version` mismatch → reload
treated as absent (client) / corrupt (server):

```json
{
  "version": 1,
  "board": "24-character string, point 0..23 left to right",
  "to_move": "red" | "green",
  "hand_red": 0..9,
  "hand_green": 0..9,
  "ply": 0,
  "plies_since_capture": 0,
  "result": "none" | "red_win" | "green_win" | "draw",
  "history": ["repetition key", "..."]
}
```

- `board` characters: `R` (red piece), `G` (green piece), `.` (empty).
  Initial board: `"........................"` (24 dots).
- `history` holds one repetition key per completed turn in order,
  **including** the initial position as element 0; it only grows (never
  rewritten except by truncating a loaded save that exceeds twice the
  legal maximum length, which cannot occur in a well-formed game).
- Canonical hash (server move rows): sha256 of
  `version|board|to_move|hand_red|hand_green|ply|plies_since_capture|result`
  joined with `|`.

## §10 Wire move format

One submitted wire move = one complete turn (placement or movement plus
its capture, if any):

```json
{ "kind": "place", "point": 17, "capture": 22 }
{ "kind": "place", "point": 17 }
{ "kind": "move", "from": 17, "to": 18, "capture": 22 }
{ "kind": "move", "from": 17, "to": 18 }
```

- `capture` is optional; `-1` and `null` are treated as absent. Any
  capture value together with a turn that formed no mill is illegal.
- `kind: "place"` requires a non-empty hand; `kind: "move"` requires an
  empty hand (the mover's).
- Notation for history/logs: placements `P17`, `P17*22` (capture),
  movements `17-18`, `17-18*22` — `*` marks a capture, the number after
  it is the removed point (same star convention as Solah Seedi).

### Validation error precedence

Game over → payload shape → point bounds (both points, capture
point) → phase/ownership (hand, origin piece) → geometry (occupied
destination, single-edge step vs legal fly) → mill/capture consistency
(new mill ⇒ required capture & legal target; no mill ⇒ capture field
must be absent).

## §11 Port parity

`server/src/nine-mens-morris/` and `src/games/nine_mens_morris/` expose
the same modules as the other engine pairs: `state` (serialization),
`move` (wire parsing/notation), `rules` (topology, generation,
application, evaluation), `validator` (pure verdicts), `index` (barrel +
`stateHash`). The server engine is authoritative for every online move;
the client port drives offline play, AI and advisory highlights, and
never decides a result the server has not confirmed.
