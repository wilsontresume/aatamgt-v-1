# Phase B — Dashboard & Angular Admin Foundation

**Status:** Complete, reviewed and accepted (2026-10-15).
**Scope:** Backend `GET /admin/dashboard` endpoint + new Angular 22 admin app
(`admin/`) with login, auth session handling, responsive shell and the
operations dashboard. Phases C–I are **not** started.

---

## 1. Implementation summary

### Backend (NestJS, additive — no schema migrations, no gameplay changes)

| File | Change |
|---|---|
| `server/src/admin/dashboard.controller.ts` | New. `GET /admin/dashboard` with validated query DTO, `@Roles('MODERATOR', 'ADMIN')`. |
| `server/src/admin/dashboard.service.ts` | New. All aggregation: users, matches, economy, health, recents. |
| `server/src/admin/admin.module.ts` | Registered the controller + provider. |
| `server/test/integration/dashboard.spec.ts` | New. 10 integration scenarios (see §5). |

Design decisions:

- **Day bucketing** uses raw SQL `DATE_FORMAT(createdAt, '%Y-%m-%d')` against
  UTC timestamps; series are **gap-filled** so every day in range appears with
  explicit zeros.
- **Human-vs-AI matches** are derived from the `MatchPlayer` relation:
  AI = `players: { some: { isAi: true } }`, human = `players: { none: { isAi: true } }`.
- **Coin flows are gross**: `issuedInRange` = Σ of rows with `amount > 0`,
  `spentInRange` = |Σ of rows with `amount < 0`|. (An earlier revision netted
  per transaction type, which understated both directions for mixed-sign types
  such as `MATCH_REWARD`; the tests caught it.)
- **Role gating**: MODERATOR and ADMIN may read everything except the
  `recent.audit` slice, which returns `null` for MODERATOR — mirroring the
  ADMIN-only rule of the existing `GET /admin/audit`.
- **Real data only**: no synthetic/invented metrics. Queue depth is a live
  `COUNT` of `WAITING` matchmaking tickets; DB latency is measured with
  `SELECT 1`; uptime is `process.uptime()`.

### Frontend (Angular 22, standalone + SCSS, no chart library)

```
admin/
├── proxy.conf.json            dev proxy → https://127.0.0.1:3443 (secure:false)
├── src/
│   ├── _theme.scss            shared palette (teal / wood / cream)
│   ├── styles.scss            global base styles
│   └── app/
│       ├── app.config.ts      router + provideHttpClient(authInterceptor)
│       ├── app.routes.ts      login | access-denied | (shell) dashboard
│       ├── core/
│       │   ├── models.ts      typed API models (Session, DashboardResponse, …)
│       │   ├── auth.service.ts    login/refresh/logout, session signal + localStorage
│       │   ├── auth.interceptor.ts Bearer header, single-flight 401 refresh + retry
│       │   └── staff.guard.ts admin/moderator gate + login redirect guard
│       ├── login/             LoginPage + AccessDeniedPage (role → /access)
│       ├── layout/shell.*     header (brand, nav, session chip, sign out)
│       └── dashboard/         DashboardPage + BarChart (hand-rolled, no deps)
```

Auth flow: `POST /api/v1/auth/login {identifier, password}` →
`{user, accessToken, refreshToken, expiresIn}`. Tokens are stored in
`localStorage` (`aatamgt.admin.session`); the interceptor attaches
`Authorization: Bearer …` and, on a 401 outside `/auth/*`, performs a
**single-flight** `POST /auth/refresh` and retries the request once. Failed
refresh logs out and redirects to `/login`. Role `USER` is rejected by
`staffGuard` and lands on the explicit access-denied screen; the backend
enforces roles independently.

---

## 2. Dashboard API

### Request

```
GET /api/v1/admin/dashboard?from=YYYY-MM-DD&to=YYYY-MM-DD&gameKey=<key>
Authorization: Bearer <access token>
```

| Parameter | Rules | Default |
|---|---|---|
| `from`, `to` | `YYYY-MM-DD`, `from ≤ to`, span ≤ 366 days, both ≤ today (UTC) | last 14 days ending today (UTC) |
| `gameKey` | `^[a-z0-9-]{3,64}$`; unknown key → **404** | all games (omitted) |

**Permissions:** `MODERATOR` or `ADMIN` (401 without a token, 403 for `USER`).
`recent.audit` is populated only for `ADMIN` (otherwise `null`).

### Response structure (real DB data only)

```jsonc
{
  "range":  { "from": "2026-10-02", "to": "2026-10-15", "gameKey": null },
  "users": {
    "total": 296, "guests": 152, "active": 295, "suspended": 0, "banned": 1,
    "registeredInRange": 296,
    "registrations": [ { "date": "2026-10-02", "count": 0 }, … ]   // gap-filled
  },
  "matches": {
    "activeNow": 35, "pendingNow": 6,          // current state, ignores range
    "totalInRange": 134,                        // respects range + gameKey
    "byStatus": { "COMPLETED": 92, "ACTIVE": 35, … },
    "humanVsHuman": 131, "humanVsAi": 3,
    "byGame": [ { "gameKey": "solah-seedi", "name": "Solah Seedi", "matches": 28 } ]
  },
  "economy": {
    "coinsCirculation": 136625, "wallets": 296,  // platform-wide, ignores range
    "issuedInRange": 141825, "spentInRange": 5200,
    "transactionsInRange": 189,
    "byType": [ { "type": "REGISTRATION_BONUS", "count": 130, "amount": 127775 } ],
    "grantsPerDay": [ { "date": "…", "count": n, "amount": n }, … ]  // credits only, gap-filled
  },
  "health": { "status": "ok", "dbLatencyMs": 1, "uptimeSeconds": 1747,
              "queueDepth": 0, "serverTime": "2026-10-15T08:43:47.383Z" },
  "recent": {
    "registrations": [ { "id", "username", "isGuest", "status", "createdAt" } ],  // 6
    "audit": [ { "id", "action", "targetType", "targetId", "createdAt",
                 "actor": { "username": "…" } } ] | null   // ADMIN only, 6
  }
}
```

Validation errors return the standard NestJS 400 body listing each failed
constraint; unknown `gameKey` returns 404.

---

## 3. Running the stack locally

### Backend (NestJS + TLS on 3443)

```bash
export PATH="/usr/local/bin:$PATH"
cd server
npm install                      # once
npx prisma migrate deploy        # schema up to date
npx tsx prisma/seed.ts           # optional: dev data (admin / Password123!)
npm run build
DATABASE_URL="mysql://root@127.0.0.1:3306/aatamgt_dev" \
PORT=3443 \
TLS_CERT_PATH=./dev-certs/dev-cert.pem \
TLS_KEY_PATH=./dev-certs/dev-key.pem \
node dist/main.js
curl -sk https://127.0.0.1:3443/health   # {"status":"ok",…}
```

Self-signed dev certs live in `server/dev-certs/` (git-ignored). Without TLS
variables the server binds plain HTTP on `PORT`.

### Frontend (Angular dev server + proxy)

```bash
export PATH="/usr/local/bin:$PATH"
cd admin
npm install                      # once
npm start                        # http://localhost:4200 (proxy → https://127.0.0.1:3443)
```

`proxy.conf.json` (`secure: false` accepts the self-signed certificate) is
wired into `angular.json → serve.options.proxyConfig`. The app calls relative
`/api/v1/*` URLs — same origin, no CORS involved in dev. Production builds:
`npm run build` → `admin/dist/admin`.

Sign in with a staff account (seeded dev admin: `admin` / `Password123!` —
dev-only credential, never used outside local development).

---

## 4. Verification screenshots

Preserved in the repository under **`builds/`**:

| File | Captures |
|---|---|
| `builds/admin-01-login.png` | Login screen (idle). |
| `builds/admin-02-dashboard.png` | Dashboard, default 14-day range, all widgets with live data. |
| `builds/admin-03-dashboard-filtered.png` | Game filter `solah-seedi` applied. |
| `builds/admin-04-dashboard-empty.png` | Empty range (2000-01-01 → 2000-01-14): empty-state banner, zeroed series, intact platform totals. |
| `builds/admin-05-dashboard-error.png` | Backend stopped mid-session → error panel with Retry. |

Captured with headless Chrome (Puppeteer) against `ng serve` + local backend
(`aatamgt_dev`, TLS 3443).

---

## 5. Test results (final run, 2026-10-15)

| Gate | Command | Result |
|---|---|---|
| Typecheck | `npm run typecheck` | clean |
| Lint | `npm run lint` | clean (0 problems) |
| Unit + integration | `npm test` | **34 suites, 422/422 passed** |
| — dashboard suite | `test/integration/dashboard.spec.ts` | 10/10 (auth × roles, validation, cap 366d, 404, gap-fill, status/HvH/HvAI, game filter, gross flows, queue depth, audit gating) |
| — regression | pre-existing `admin-dashboard.spec.ts` | passed unchanged |
| Backend build | `npm run build` | clean |
| Angular production build | `admin: npm run build` | clean — 276 kB raw / 75.9 kB transfer initial |
| Godot client regression | `AATAMGT_API_URL=https://127.0.0.1:1 Godot --headless --script tests/validate.gd` | **639 checks, 0 failures** |
| E2E smoke | login → dashboard through `ng serve` proxy | live data rendered (296 users / 134 matches / 136,625 coins) |

Test expectations for windowed metrics are computed from the database at test
time (the shared `aatamgt_test` database accumulates rows across suite runs);
game-key-scoped assertions remain absolute because seeded game keys are
unique per run.

---

## 6. Known limitations

1. **Queue depth** counts durable `WAITING` tickets in the database; the
   in-memory matchmaking queue holds no rows, so the number can momentarily
   lag reality. Not a synthetic value — it is what the DB actually knows.
2. **`activeNow` / `pendingNow` / `queueDepth` / circulation** ignore the date
   filter by design (current-state metrics); the range applies only to
   `*InRange` and the daily series.
3. Login throttling (5 bad attempts / 15 min) surfaces as a generic sign-in
   failure; the API's `Retry-After` hint is not yet rendered in the UI.
4. The games dropdown is loaded once per page load (no live refresh).
5. Charts are simple hand-rolled bars — no tooltips with per-day drill-down,
   no export/CSV (deferred to later phases).
6. No pagination anywhere yet (recents are fixed at 6 rows) — arrives with
   Phase C's user table.
7. Dev-only: the local backend may be left running on 3443 and `ng serve` on
   4200 during development; neither is required for production builds.

## 7. Git hygiene (verified)

- No `.env` files, tokens or real credentials tracked; `server/.env` is
  ignored; `server/.env.example` contains placeholders only.
- **Removed from tracking in this change set** (they were tracked before):
  `dev-certs/dev-key.pem` + `dev-certs/dev-cert.pem` (self-signed private
  key) and the empty leftover `server/prisma/dev.db`; matching ignore rules
  added. Files remain on disk.
- Test-fixture passwords (e.g. `Password123!` in
  `server/test/**`) are generated test data, not secrets.
- `admin/node_modules`, `admin/dist`, `server/dist` are ignored by their
  project `.gitignore`s.
