# Backend-Managed Game Tiers — Completion Report

**Date:** 2026-10-14  
**Scope:** Tier catalog (DB-backed), admin CRUD, matchmaking/challenge integrity, dynamic Godot client  
**Status:** Backend green (typecheck + lint + 407 tests) · Godot offline suite green (635 checks) · Social suite green (88 checks) · Emulator verified

---

## 1. Schema

New Prisma model `Tier` (`server/prisma/schema.prisma`):

| Field | Type | Notes |
|---|---|---|
| `id` | `VarChar(64)` PK | slug, e.g. `bronze` — no surrogate id |
| `name` | `VarChar(64)` | display name shown to players |
| `gameKey` | `VarChar(64)?` | null = global (all games) |
| `entryCostCoins` | `Int` default 0 | stake debited on match activate |
| `rewardMultiplierBp` | `Int` default 10000 | payout = `floor(cost × multBp / 10000)` |
| `active` | `Boolean` default true | disabled tiers hidden from catalog and rejected at queue/challenge |
| `displayOrder` | `Int` default 0 | client sorts by this |
| timestamps | createdAt/updatedAt | |

Migration: `server/prisma/migrations/20261014120000_tiers_table/migration.sql` (new file; applied migrations were never edited).

No FK on `GameMatch.tierId` — historical rows may reference deleted tiers; existence + active state are re-validated at service level.

---

## 2. Seed

`server/prisma/seed.ts` upserts exactly three tiers (no Free tier):

| id | name | entryCostCoins | rewardMultiplierBp | winner payout |
|---|---|---|---|---|
| `bronze` | Bronze | 50 | 12500 | 62 coins |
| `silver` | Silver | 100 | 20000 | 200 coins |
| `gold` | Gold | 500 | 30000 | 1500 coins |

**Reward decision:** keep `rewardMultiplierBp` as the canonical field; the API returns a computed `rewardCoins = floor(entryCostCoins × multBp / 10000)`. Payout formula is unchanged (`MatchesService.creditMatchRewards`).

**Approval note:** seed values above are the documented defaults for product approval. Admins can change cost/reward via the admin endpoints; seed only sets the initial rows and is idempotent.

---

## 3. Endpoints

### Player (read-only, auth required)

| Method | Path | Notes |
|---|---|---|
| `GET` | `/tiers` | Active tiers, ordered by `displayOrder`. Optional `?gameKey=` filters to global + matching. Returns `GameTier[]`: `{id, label, costCoins, rewardMultiplierBp, minBalance, rewardCoins}`. |

### Admin (role `ADMIN` required)

| Method | Path | Body | Notes |
|---|---|---|---|
| `GET` | `/admin/tiers` | — | All tiers (including inactive), ordered |
| `GET` | `/admin/tiers/:id` | — | Single tier or 404 |
| `POST` | `/admin/tiers` | CreateTierBody | 201; audit `tier.create` |
| `PATCH` | `/admin/tiers/:id` | UpdateTierBody | Partial update; audit `tier.update` |
| `PATCH` | `/admin/tiers/:id/active` | `{active: boolean}` | Enable/disable; audit `tier.set_active` |

DTO validation: `id` matches `/^[a-z0-9-]{3,64}$/`, `entryCostCoins` 0–1 000 000, `rewardMultiplierBp` 10 000–1 000 000, `displayOrder` 0–1000. Ordinary users receive 403 on all admin routes (global `RolesGuard`).

Audit log writes go through the existing `AdminService.audit(actorId, action, targetType, targetId, data)` into `AdminAuditLog`.

---

## 4. Integrity rules

- **Queue** (`POST /matchmaking/queue`): `tiers.requireActiveForGame(tierId, gameKey)` — rejects unknown or disabled tiers (400). Balance check is eligibility-only; coins are debited when the match activates, never on selection.
- **Challenge create** (`POST /challenges`): same `requireActiveForGame` check; `tierId` stored on the `Challenge` row.
- **Challenge accept**: re-validates the tier is still active, re-derives `stakeCoins` from the DB tier, and checks the acceptor's balance before the PENDING→ACCEPTED flip. Failure reverts the challenge to PENDING.
- **Match create / createWithAiOpponent** (internal): when `tierId` is present, re-derives `stakeCoins` from the DB tier — client-supplied `stakeCoins` is ignored. Public `POST /matches` still 403s any client-supplied `stakeCoins`/`tierId`.
- **Reward path** (`creditMatchRewards`): `tiers.byId(match.tierId)` may return an inactive tier (historical matches still pay out); unknown id → no credit.
- **Removed dual source of truth:** the eight `tier.*` SystemConfig keys were deleted from `CONFIG_KEYS` — the DB is now the sole owner of cost/reward.

---

## 5. Godot client

- `scenes/screens/game_entry.tscn`: removed FreeButton/BronzeButton/SilverButton/GoldButton; added a hidden `RetryButton`.
- `src/ui/screens/game_entry.gd`: `_load_tiers()` builds toggle Buttons dynamically from `GET /tiers` items (label + cost). On failure: shows the error message, reveals Retry, and **does not fabricate a Free tier**. Actions row stays hidden until a valid tier is selected.
- `src/core/services/matchmaking_service.gd`: removed `TIER_IDS` const and the `"free"` default on `queue()` — the client never hard-codes a catalog.
- `src/ui/screens/friend_challenge.gd`: no `"free"` default; send is blocked when no tier is selected.

---

## 6. Tests

### Backend (jest)

| Suite | Result |
|---|---|
| Full backend suite (33 suites) | **407 / 407 pass** |
| `test/integration/tiers-admin.spec.ts` (new) | 7 tests — admin CRUD, USER 403, disabled-tier queue reject, insufficient balance, tier identity through matchmaking, audit |
| `test/integration/matchmaking.spec.ts` (updated) | DB-seeded tiers, bronze cost 50, disabled-tier hidden, no Free |
| `test/unit/matches.service.spec.ts` (updated) | `requireActiveForGame` mock; server-authoritative stake; disabled-tier reject |
| `npm run lint` | clean |
| `npm run build` | clean |
| `scripts/test-db.mjs deploy` | migration applies cleanly on MySQL 8 |

### Godot (headless)

| Suite | Result |
|---|---|
| `tests/validate.gd` | **635 / 0 fail** |
| `tests/phase11/social_validate.gd` | **88 / 0 fail** |

### Emulator

Screenshots in `builds/tier-dyn-*.png`:

1. Dynamic cards load: Bronze 50 / Silver 100 / Gold 500 (no Free).
2. Selecting Bronze: "Entry 50 coins · winner takes 62 coins"; Play with Friend / Play Online revealed.
3. Empty-catalog + Retry path verified while the DB was unseeded.

---

## 7. Unresolved economy decisions

1. **Payout formula** — currently multiplier-based (`floor(stake × multBp / 10000)`). Alternative: flat payout per tier. Needs product sign-off; the seed multipliers above encode the current intent.
2. **Free tier** — intentionally not seeded. If a free-play tier is wanted, admins add it via `POST /admin/tiers` with `entryCostCoins: 0`.
3. **Per-game tiers** — `gameKey` on a Tier scopes it to one game (null = global). Currently all seeds are global; whether future events should use per-game tiers is undecided.
4. **Stake debit timing** — debited on match activate, not on queue/challenge-create. Abandoned queues therefore never touch the wallet; this matches the spec but is worth confirming with finance.
