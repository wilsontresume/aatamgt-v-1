# Aadu Puli Aattam — Rule Specification (Phase 4)

This is the exact ruleset Phase 4 implements. It is fixed before coding; the
engine (`src/games/aadu_puli/`) implements only what is written here.

## 1. Sources and how conflicts were resolved

| Rule | Sources consulted | Chosen |
|---|---|---|
| Board: 23 points, apex + three rows of six + base row of four | xchess.net rules (explicit index + line list); classic-board-games.com strategy page ("rows 1,2,3 have six positions each, bottom row has 4") | 23-point board, exact index below |
| Start: 3 tigers on inner apex triangle, 15 goats in hand, goats move first | classic-board-games rules 1–5; xchess "Starting position" (`t..tt… g 15 0`); traditionalgames.co.in | tigers on 0, 3, 4 |
| Tiger win | classic rule 9 ("5th goat is eaten"); xchess ("capture 5"); traditionalgames ("kill 5 Aadus") — one outlier source says 6, a children's worksheet says all 15 | **5 captures** |
| Goat win | classic rule 10 ("none of the tigers can move"); xchess ("every tiger has no legal step and no legal jump") | **all tigers immobilised** |
| Draw | classic rule 11 ("30 moves each"); xchess ("60 plies"); one modern app uses repetition instead | **60 plies (30 moves per side)** |
| Capture is optional, single hop, no forced jump | classic rule 7; xchess (explicitly: no forced capture, no second hop) | as stated |

## 2. Board

23 numbered points:

```
            0
     1   2  3  4  5   6
     7   8  9 10 11  12
    13  14 15 16 17  18
        19  20  21  22
```

Lines are ordered point sequences ("polylines"). A quiet move goes from a
point to the **next point on a line**. A jump uses **three consecutive
points of one line**.

| id | line |
|---|---|
| L1 | 0–2–8–14–19 |
| L2 | 0–3–9–15–20 |
| L3 | 0–4–10–16–21 |
| L4 | 0–5–11–17–22 |
| H1 | 1–2–3–4–5–6 |
| H2 | 7–8–9–10–11–12 |
| H3 | 13–14–15–16–17–18 |
| H4 | 19–20–21–22 |
| C1 | 1–7–13 |
| C2 | 6–12–18 |

Derived adjacency (consecutive pairs): point 0 is adjacent to 2, 3, 4, 5
(**not** to 1 or 6); point 19 is adjacent to 14 and 20 (**not** to 13 or 18).

## 3. Pieces and starting position

- **3 tigers** on points **0, 3, 4** (the inner apex triangle).
- **15 goats in hand** (off the board); every other point empty.
- **Goats move first.** Side alternates strictly every ply; no passing.

## 4. Turn system and legal movement

### 4.1 Goat turn while `goats_in_hand > 0` (placement phase)
- The goat side **places** exactly one goat on **any empty point**.
- Goats may **not slide** during this phase and never capture.
- Placement continues until the 15th goat enters.

### 4.2 Goat turn when `goats_in_hand == 0` (slide phase)
- The goat side slides exactly one goat to an **adjacent empty point**
  (adjacency per §2). Goats never jump, never capture, never move tigers.

### 4.3 Tiger turn (always, including during goat placement)
Exactly one tiger does one of:
- **Step** to an adjacent empty point, or
- **Jump (capture)**: over **exactly one adjacent goat** onto the point
  **immediately beyond** on the **same line** (three consecutive points of
  one line, in either direction), landing point must be empty.
  - May not jump a tiger, may not jump two goats, may not turn a corner
    mid-jump (the three points must belong to one line).
  - **One capture per turn**, no second hop, **capture is optional**
    (if both a step and a jump are legal, either may be played).
  - The jumped goat is removed permanently (never returns to hand).

### 4.4 Notation
Placement `12`, step `0-2`, jump `0-8*` (from–to, `*` marks capture).

## 5. Outcome conditions

Evaluated after every applied move, in this order:

1. **TIGERS_WIN** — `goats_captured == 5` (checked the moment the 5th
   goat is removed).
2. **GOATS_WIN** — side to move is **tigers** and every tiger has no
   legal step and no legal jump (evaluated at the start of a tiger turn).
3. **TIGERS_WIN** — side to move is **goats**, `goats_in_hand == 0`, and
   no goat has a legal slide. *(Sourced from xchess. Note: with standard
   piece counts this is provably unreachable — no arrangement of the 5–9
   empty points exists whose only neighbours are the 3 tigers. The branch
   is implemented anyway and covered by a white-box test.)*
4. **DRAW** — `ply >= 60` (each side has made 30 moves) and no winner
   above. Wins take precedence over the draw.

During placement there is always an empty point (max 18 pieces on 23
points), so condition 3 cannot fire while goats remain in hand.

## 6. Undo

**Allowed.** The game is deterministic, perfect-information and has no
clocks, randomness or hidden state, so restoring a previous snapshot
(including counters) reproduces a legal earlier position exactly. Undo is
available from any ply (including from a terminal position, which clears
the result) down to the start position.

## 7. Restart

Any time, behind a confirmation dialog; resets to §3 and clears the
saved game.

## 8. Game state serialization

`AaduPuliGameState.serialize() -> Dictionary` (JSON-safe):

```
{ "version": 1,
  "board": "t..tt..................",   # 23 chars: t / g / .
  "side_to_move": "goats" | "tigers",
  "goats_in_hand": 0..15,
  "goats_captured": 0..15,
  "ply": int >= 0,
  "result": "none" | "goats_win" | "tigers_win" | "draw" }
```

`deserialize()` rejects malformed data (wrong length, unknown symbols,
side/result, counts out of range, conservation violation
`hand + on_board + captured == 15`, tiger count != 3).

A compact FEN mirror of the published format is also provided:
`to_fen()` / `from_fen()` → `"t..tt.................. g 15 0"`
(board, side, hand, ply; `captured` is derived).

The screen persists the current game with `serialize()` after every move
and restores it with `deserialize()` on open.

## 9. Scope (explicit non-goals)

- Completely **offline**; no server, no multiplayer, no networking.
- **No opponent / no AI**: a single local player controls both sides,
  playing the moves of the side whose turn it is (hot-seat by rule).
- No coins, ads, purchases, timers or ratings.
- **Architecture**: the rules engine (`AaduPuliGameState`,
  `AaduPuliRules`, `AaduPuliMove`, `AaduPuliValidator`) is independent of
  any UI. The UI only renders state and submits requested moves; it never
  computes legality itself.
