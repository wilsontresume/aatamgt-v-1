# Development database — migration drift investigation and baseline repair

Status: **repaired and verified** (2026-10-16). This document records what was
wrong, the safe repair procedure that was validated on a clone and then applied
to `aatamgt_dev`, and the development-only demo records that exist in that
database.

No migration file was modified, no table data was deleted, and no
`migrate reset` / destructive `migrate dev` was run at any point.

## 1. What was wrong

`prisma migrate status` / `migrate deploy` against `aatamgt_dev` failed with
`Duplicate column name 'tierId'`, and `prisma migrate dev` demanded a
destructive reset. Investigation (all read-only) found:

- The **schema itself was not drifted**: `prisma migrate diff --from-url
  aatamgt_dev --to-schema-datamodel prisma/schema.prisma --script` returned
  *"This is an empty migration"* — every column, index and constraint the
  schema expects already exists.
- The fault was entirely in the `_prisma_migrations` **ledger**:

| Migration | Ledger state | Actual DDL |
|---|---|---|
| `20261013160000_matchmaking_tiers_ai` | zombie row: `started_at=2026-10-16 04:51`, `finished_at=NULL`, `applied_steps_count=0` | fully present (`GameMatch.tierId`, `MatchPlayer.isAi/aiName`, nullable `MatchPlayer.userId`/`MatchMove.userId`, `MatchmakingTicket` + FK) |
| `20261013170000_challenge_tier` | no row | present (`Challenge.tierId`) |
| `20261014120000_tiers_table` | no row | present (`Tier` table + indexes) |

- Root cause: the tier work of 2026-10-13/14 applied its DDL to the dev
  database **outside the migration workflow** (consistent with `prisma db
  push`, which changes the schema without writing `_prisma_migrations` rows).
  A later `prisma migrate deploy` attempt then started
  `matchmaking_tiers_ai`, failed on the already-existing `tierId` column
  (MySQL DDL is non-transactional; the failed statement left the zombie row),
  and `challenge_tier`/`tiers_table` had no rows at all.

## 2. Safe baseline-repair procedure (validated)

Run every step from `server/`. Never use `migrate reset`; never edit an
applied migration file.

1. **Backup first** (always):

   ```bash
   mysqldump -uroot -h127.0.0.1 aatamgt_dev > aatamgt_dev.backup.$(date +%Y%m%d).sql
   ```

2. **Prove the schema matches** (must print *This is an empty migration*):

   ```bash
   npx prisma migrate diff \
     --from-url "mysql://root@127.0.0.1:3306/aatamgt_dev" \
     --to-schema-datamodel prisma/schema.prisma --script
   ```

   If this is **not** empty, stop: reconcile the real schema difference by hand
   first (complete or reverse the mismatched DDL), then re-run until empty.
   Baseline-repair only fixes bookkeeping, never structural drift.

3. **Rehearse on a clone**, not on the live dev DB:

   ```bash
   mysql -uroot -h127.0.0.1 -e "CREATE DATABASE aatamgt_dev_repaircheck"
   mysqldump -uroot -h127.0.0.1 aatamgt_dev | mysql -uroot -h127.0.0.1 aatamgt_dev_repaircheck
   ```

4. **Mark the already-present migrations as applied** (bookkeeping only —
   executes no DDL, touches no table data). Use the clone's URL for rehearsal:

   ```bash
   DATABASE_URL="mysql://root@127.0.0.1:3306/aatamgt_dev_repaircheck" \
     npx prisma migrate resolve --applied 20261013160000_matchmaking_tiers_ai
   DATABASE_URL="mysql://root@127.0.0.1:3306/aatamgt_dev_repaircheck" \
     npx prisma migrate resolve --applied 20261013170000_challenge_tier
   DATABASE_URL="mysql://root@127.0.0.1:3306/aatamgt_dev_repaircheck" \
     npx prisma migrate resolve --applied 20261014120000_tiers_table
   ```

   The zombie row for `matchmaking_tiers_ai` is repaired by the same
   `resolve --applied` call (it rewrites the unfinished row as applied).

5. **Verify the rehearsal**:

   ```bash
   DATABASE_URL=…aatamgt_dev_repaircheck npx prisma migrate status   # "up to date"
   DATABASE_URL=…aatamgt_dev_repaircheck npx prisma migrate deploy   # "No pending migrations to apply"
   ```

6. Only after the rehearsal passes, repeat step 4 with
   `DATABASE_URL=…aatamgt_dev`, then step 5 against `aatamgt_dev`, and confirm
   row counts (users, audit, …) are unchanged.

7. Future schema changes go through normal `migrate dev` → commit →
   `migrate deploy` again.

### Validation result (2026-10-16)

- Clone rehearsal: status *"Database schema is up to date!"*, deploy
  *"No pending migrations to apply."*
- Applied to `aatamgt_dev`: same result. Data intact afterwards
  (297 users, 68 audit rows, 3 tiers, 2 moderation notes).
- The test database (`aatamgt_test`, managed by the jest global setup) was
  never affected — it applies migrations normally on every test run.

## 3. Development-only demo records (documented, not deleted)

Created while capturing Phase C screenshots and running acceptance checks.
All are honest audit/note entries with reasons that say they are demo or
acceptance data; they were **left in place** (deleting them would falsify the
audit trail).

**Moderation notes (2)** — both on `guest_8402b406`:

| Author | Body | Time (UTC 2026-10-16) |
|---|---|---|
| admin | `Demo note (Phase C): reviewed match history and wallet activity — no anomalies found.` | 05:15 |
| phasec_mod | `MOD API check note - Phase C acceptance.` | 05:23 |

**Audit rows created 2026-10-16 (9)**:

- `moderation.note.create` ×2 (the two notes above)
- `user.status` ×2 on `guest_21b4db0e` — screenshot demo suspend/reactivate
  (reasons contain "Demo audit entry: …"); user left **ACTIVE**
- `user.role` ×1 — `phasec_mod` USER → MODERATOR (acceptance fixture)
- `user.status` ×4 on `phasec_mod` — suspend/login-rejection/reactivate cycles
  (reasons contain "Phase C acceptance: …"); user left **ACTIVE**

**Test account**: `phasec_mod` / `Password123!` — MODERATOR, ACTIVE, kept as a
reusable moderator fixture for future phases.

**Temporary role stash** (acceptance of the last-admin guard): `phase15_admin`
and `sec_admin_mv20toxt` were switched USER-side to MODERATOR and back via
plain SQL; final state verified **ADMIN/ACTIVE** for both, and these SQL
switches produced no audit rows.
