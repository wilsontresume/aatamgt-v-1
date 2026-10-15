# Multiplayer-First Game Entry — Completion Report (Workflow Change 2)

**Date:** 2026-10-13  
**Scope:** Aadu Puli Aattam · Solah Seedi · Nine Men's Morris  
**Status:** Backend green (typecheck + 399 tests) · Godot offline suite green (629 checks) · Social suite green (88 checks)

---

## 1. What shipped

### 1.1 Game entry screen (replaces direct mode-selection)

PLAY on the main menu now opens a shared **game entry** screen for the selected carousel game:

| Element | Behaviour |
|---|---|
| Title / coins | Selected game title + live wallet (`GET` via session) |
| Stake tier | Free · Bronze · Silver · Gold (server catalog `GET /tiers`) |
| Tier detail | Entry cost × reward multiplier from server config |
| **Play with Friend** | Sets matchmaking pending `{game_key, tier_id}` → **friend challenge** screen |
| **Play Online** | `POST /matchmaking/queue` → poll status → hand off to game screen |
| Queue panel | “Searching…”, cancel, vs-AI notice when the server falls back |
| Matched | `App.online.request_auto_online(matchId)` → navigate to the game screen |

Hot-seat and local Vs-AI remain available **inside** each game screen when the player opens it without an entry-flow hand-off (ModeRow stays visible in that case).

### 1.2 Friend challenge (entry flow)

New `friend_challenge` screen: pick a friend or look up a player ID (`GET /users/lookup/:username`), send a staked challenge (`POST /challenges` with `tierId`), show the share code, copy invite text.

### 1.3 Server-controlled AI fallback

When matchmaking times out with no human pair, the server seats a **GuestXXXXX** AI player (`MatchPlayer.isAi`), runs the shared rules engine via `MatchAiDriver`, and completes the match with human-only ranking/analytics.

### 1.4 Economy (approved)

| Tier | Stake | Multiplier |
|---|---|---|
| Free | 0 | 1× |
| Bronze | 25 | 1.25× |
| Silver | 100 | 2× |
| Gold | 300 | 3× |

- Stake deducted on match activate (idempotent `match_stake:${matchId}:${userId}`).
- Human winner credited stake × mult on finalize (`match_reward:${matchId}`).
- Draw refunds each human (`match_refund:${matchId}:${userId}`).
- All through `WalletService` type `MATCH_REWARD`; client cannot set stake/tier on `POST /matches` (403).

---

## 2. Client contract

| Service | API |
|---|---|
| `MatchmakingService` | `list_tiers` · `queue` · `status` · `cancel_queue` · `lookup_player` · `set_pending` / `take_pending` · `game_key_for` / `screen_for_game_key` |
| `OnlineMatchService` | `request_auto_online(matchId?)` · `consume_auto_online()` · `take_auto_match_id()` (all one-shot) |
| `SocialService` | `create_challenge(game_key, invitee_username?, tier_id?)` |
| Navigation | `&"game_entry"` · `&"friend_challenge"` |
| Params | `main.gd` calls `apply_params` **before** `add_child` so `_ready` sees `game_id` |

Each game screen’s `_online_bootstrap()` prefers `take_auto_match_id()` over `find_resumable_match()`, and hides ModeRow/OnlineRow when auto-online was requested.

---

## 3. Server contract

| Route | Notes |
|---|---|
| `GET /tiers` | Free / Bronze / Silver / Gold from SystemConfig |
| `GET/POST/DELETE /matchmaking/{status,queue}` | Queue has `@HttpCode(200)` |
| `POST /matches` | Rejects client `stakeCoins`/`tierId` with 403 |
| `GET /users/lookup/:username` | `{id, username}` or 404 |
| Challenges | `tierId` optional; accept creates staked match |

Modules: `MatchmakingModule` (queue + AI driver), `TiersModule` (shared), `MatchesModule` (engineTurn + submitAiMove + rewards).

Env: `MATCHMAKING_TIMEOUT_MS` (default 8000), `MATCHMAKING_AI_MOVE_DELAY_MS` (default 1200).

---

## 4. Tests

| Suite | Result |
|---|---|
| Backend typecheck | Clean |
| Backend full regression | **32 suites · 399 tests · 0 failures** (incl. `matchmaking.spec.ts`) |
| Godot `tests/validate.gd` | **635 checks · 0 failures** (tier-workflow + workflow-2 contract blocks) |
| Godot `tests/phase11/social_validate.gd` | **88 checks · 0 failures** |

Migrations applied (dev + test): `20261013160000_matchmaking_tiers_ai`, `20261013170000_challenge_tier`.

---

## 5. Files (high level)

**Client (new):** `matchmaking_service.gd`, `game_entry.gd/.tscn`, `friend_challenge.gd/.tscn`  
**Client (edited):** `app.gd`, `main.gd`, `navigation_service.gd`, `social_service.gd`, `online_match_service.gd`, `main_menu.gd`, `aadu_puli.gd`, `solah_seedi.gd`, `nine_mens_morris.gd`, `challenge.gd`, `tests/validate.gd`  
**Server:** schema + 2 migrations, `ai/ai-move.ts`, `matchmaking/*`, `matches/*`, `challenges/*`, `users.controller.ts`, `friends/*`, `realtime/user-presence.service.ts`, `events/match-events.service.ts`, `leaderboards`/`rankings` null-AI fixes, `app.module.ts`

---

## 6. Emulator verification (2026-10-13)

Device: `emulator-5554` · APK: `builds/aatamgt-debug.apk` · Backend: local TLS on `:3443` via `adb reverse`.

### Verified

| Flow | Result |
|---|---|
| Guest login → main menu | OK |
| PLAY → `game_entry` | OK (`game_id=aadu_puli` passed) |
| Tiers load | Free · Bronze · Silver · Gold + detail line |
| **Play Online** → queue → AI fallback | Server seats `GuestXXXXX`; client auto-online hand-off navigates to game |
| Entry-flow hides ModeRow + OnlineRow | Confirmed after `_entry_flow` fix (below) |
| Live match vs AI | Online mode label, Resign, turn timer, move submit |
| Turn timer | Ran out → “You lose — ran out of time” (server-driven) |
| **Cancel search** | Status: “Search cancelled”; buttons re-enabled |
| **Play with Friend** → `friend_challenge` | Screen loads with game + tier |
| Username lookup | `abctestuserX` → “Found: abctestuserx” |
| **Send Challenge** | “Challenge sent… Share this code: **2Z6YE2MJ**” · server row PENDING |

### Bugs found and fixed during the device pass

1. **Matchmaking response shape** — `game_entry.gd` read `res.status` / `res.vsAi` / `res.matchId` at the top level; the API client nests the payload under `res.body`. Status showed “Unexpected matchmaking response” even though the server returned `matched`. Fixed: unwrap `res.body` in `_handle_queue_result`, `_on_poll_timeout`, `_on_matched`.
2. **OnlineRow re-shown after hand-off** — `_refresh()` sets `_online_row.visible = _online_mode`, which immediately undid the auto-online hide. Added `_entry_flow` flag (set when `consume_auto_online()` is true) so `_refresh()` keeps ModeRow and OnlineRow hidden for the whole hand-off match. Applied to all three game screens.
3. **Client HTTP timeout too tight** — `ApiClient.TIMEOUT_SECONDS` was `6.0`; challenge create (game load + invitee lookup + rate checks + unique code + notification) measured ~3.5–5.9s on the emulator and aborted at 6s. Raised to `15.0`. First attempt aborted client-side but still created the challenge server-side (idempotent UX risk); after the bump the UI shows the share code.

### Not fully exercised

- Bronze/Silver/Gold stake paths on device (guest had 0 coins — eligibility correctly would reject paid tiers).
- Accept/decline a challenge from a second client (single-device pass).
- Solah Seedi / Nine Men’s Morris entry hand-off (same code path as Aadu Puli; offline suites cover the shared contract).

### Device-pass notes

- `adb` goes offline across long export steps; recover with `adb kill-server; adb start-server`, then `adb reverse tcp:3443 tcp:3443`.
- Launch component is `com.aatamgt.app/com.godot.game.GodotAppLauncher` (direct `GodotApp` is not exported).
- Server must be rebuilt (`npm run build`) before restart — stale `dist/` 404s on new matchmaking routes.

---

## 7. Tier-workflow fix (2026-10-14)

### Problem

Three defects on the device pass after the 2026-10-13 fixes:

1. **Free tier was pre-selected** — `game_entry.tscn` had `button_pressed = true` on `FreeButton`; `_selected_tier` defaulted to `"free"`. The spec requires no default.
2. **ActionsRow was always visible** — the player could hit Play with Friend / Play Online without choosing a stake tier.
3. **"Loading tiers…" never cleared on success** — `_load_tiers()` only called `_refresh_tier_detail()` when a tier was already selected; with the new "no default" rule the label stayed stuck on "Loading tiers…".

### Fix

- `scenes/screens/game_entry.tscn`: removed `button_pressed = true` from `FreeButton`; `ActionsRow` starts `visible = false`; `TierDetail` default text is "Select a stake tier to continue".
- `src/ui/screens/game_entry.gd`:
  - `_selected_tier` defaults to `""`; `_actions_row` is wired and hidden in `_ready()`.
  - `_wire()` clears any pre-pressed tier button via `set_pressed_no_signal(false)`.
  - `_on_tier_pressed()` reveals `_actions_row` after setting the selection.
  - `_refresh_tier_detail()` shows "Select a stake tier to continue" when nothing is selected and "Tier details unavailable" when data is missing (no more "Loading tiers…" from the detail path).
  - `_load_tiers()` always calls `_refresh_tier_detail()` after a successful fetch (fixes the stuck "Loading tiers…" label).
- `tests/validate.gd`: new workflow checks — actions hidden on entry, no pre-selected button, selecting Free reveals the actions and shows the Free-tier detail copy.

### Root cause of the "Network error" on the first device pass

The backend was regenerated with a **new** TLS cert in `dev-certs/dev-cert.pem` (root), but the APK bundled the **old** cert from `server/dev-certs/dev-cert.pem`. The TLS handshake failed and the UI showed "Network error. Check your connection and try again." Synced `server/dev-certs/dev-cert.pem` to match the running backend cert and re-exported.

---

## 8. Emulator verification — tier workflow (2026-10-14)

Device: `emulator-5554` · APK: `builds/aatamgt-debug.apk` · Backend: local TLS on `:3443` via `adb reverse`.

### Verified

| Flow | Result |
|---|---|
| PLAY → `game_entry` (no tier selected) | ActionsRow hidden · TierDetail: "Select a stake tier to continue" |
| Tiers load from server | Free · Bronze · Silver · Gold |
| Select Free | TierDetail: "Free play · winner keeps bragging rights (1x)" · ActionsRow revealed |
| **Play Online** → queue | "Queued · free" · "Searching for an opponent…" · Cancel search available |
| AI fallback | Server seats GuestXXXXX; hand-off navigates to Aadu Puli Aattam online |
| Live match vs AI | Online mode label, Resign, turn timer, move submit |
| Turn timer | Ran out → "You lose — ran out of time" (server-driven) |

### Not fully exercised

- Bronze/Silver/Gold stake paths on device (guest had 0 coins — eligibility correctly would reject paid tiers).
- Accept/decline a challenge from a second client (single-device pass).
- Solah Seedi / Nine Men's Morris entry hand-off (same code path as Aadu Puli; offline suites cover the shared contract).

### Device-pass notes

- `adb` goes offline across long export steps; recover with `adb kill-server; adb start-server`, then `adb reverse tcp:3443 tcp:3443`.
- Launch component is `com.aatamgt.app/com.godot.game.GodotAppLauncher` (direct `GodotApp` is not exported).
- Server must be rebuilt (`npm run build`) before restart — stale `dist/` 404s on new matchmaking routes.
- Godot draws its own UI; `uiautomator dump` only sees the SurfaceView. Use `input tap` / `input swipe` with the on-screen coordinates from a screenshot.
- Backend must be **stopped** for the Godot offline suite; otherwise the network-dependent checks report online instead of the expected offline hints (7 failures that clear when the backend is down).

---

## 9. How to re-verify

```bash
# Backend
cd server && npm run typecheck && npm test

# Godot offline (backend may be running for TLS noise only)
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tests/validate.gd
/Applications/Godot.app/Contents/MacOS/Godot --headless --path . -s res://tests/phase11/social_validate.gd
```
