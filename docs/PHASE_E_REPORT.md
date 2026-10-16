# Phase E — Game Asset Studio, Tier Management & Godot Integration

**Date:** 2026-10-16  
**Scope:** Content model + admin APIs, storage & image validation, tier/reward snapshot safety, Angular Content Studio, Godot manifest client with caching/fallback, tests + gates, screenshots + evidence.

---

## What was built

### Backend (`server/src/content/`)

| File | Purpose |
|---|---|
| `storage/storage.service.ts` | Pluggable adapter (`local` / `s3`). Local driver writes under `ASSET_STORAGE_LOCAL_ROOT` using the deterministic key `<first-two-hex>/<asset-id>-v<version>.<ext>`. |
| `image-validation.ts` | Magic-byte signature check (PNG, JPEG, WebP, GIF). Min 16 px, max 4096 px. Rejects extension-only spoofing. |
| `assets.service.ts` | Upload (multipart), replace (new immutable version row), activate/deactivate, version history, file download with `Cache-Control: public, max-age=31536000, immutable` + `ETag`. |
| `content-manifest.service.ts` | Atomic publish: reads live DB → validates → freezes immutable manifest row → returns version + sha256 checksum. Rollback re-publishes an old row verbatim (does not rebuild from DB). |
| `assets.admin.controller.ts` | ADMIN: CRUD + replace + activate. |
| `content.admin.controller.ts` | ADMIN: draft, publish, publications list, rollback. |
| `content.public.controller.ts` | PUBLIC: manifest + asset file download. |
| `content.module.ts` | Wires everything together. |

**Permissions:** ADMIN-only mutations; MOD read access on draft/publications; PUBLIC on manifest + file route.

**Audit:** Every upload, replace, activate, publish, rollback writes an `AdminAuditLog` row (`actorUserId` / `action` / `targetType` / `targetId`).

**Schema migration:** `20261016072316_phase_e_content` (applied; no drift). Adds content asset tables, publish history, board theme + tier display columns, `rewardMultiplierBp` snapshot on matches.

**Configuration:** `ASSET_STORAGE_DRIVER`, `ASSET_STORAGE_LOCAL_ROOT`, `ASSET_MAX_UPLOAD_BYTES`, `ASSET_S3_*` (names only — see `docs/content-assets.md`).

### Angular Content Studio (`admin/src/app/content/`)

Five tabs under `/content` route:

| Tab | Screenshot |
|---|---|
| Games | `builds/admin-19-content-games.png` |
| Assets | `builds/admin-20-content-assets.png` |
| Tiers & Coins | `builds/admin-21-content-tiers.png` |
| Board Designer | `builds/admin-22-content-board.png` |
| Publish History | `builds/admin-23-content-publish.png` |

Nav link added in `shell.html`. `ng build` green (13.2 s).

**Bug fixed during screenshot work:** `listTiers()` was typed as `{ items: AdminTier[] }` but the backend returns a bare array; `tiers.items` was `undefined`, causing `forkJoin` to hang on the spinner. Fixed in `content.service.ts` + `content.ts`.

### Godot Content Client (`src/core/content/`)

| File | Purpose |
|---|---|
| `content_manifest.gd` | `ContentManifest` — parse envelope, from-cache, games/games-ordered, game_entry, tiers/tier-entry, asset-entry/checksum, home-background-id, board-skin/board-theme, tier-display/tier-display-by-name, static `sha256_hex`, `is_hex_color`, `is_asset_id`, `ref_id`, `screen_game_key`. |
| `content_service.gd` | `ContentService` (RefCounted) — `start()` (load cache → refresh), `refresh()` (GET manifest, checksum-compare skip, atomic cache write, clear textures), `texture_for()` (read `user://content/assets/<id>`, lazy download with sha256 verify), visual accessors. Signals: `manifest_changed`, `asset_ready`, `refresh_finished`. |

**Wiring:** `app.gd` — `var content: ContentService`, `content = ContentService.new(api_client)` in `_init`, `content.start()` in `_ready`.

**Visual hooks:**
- `cosmetic_service.gd` — `apply_board_skin(board, base_skin)` merges published skin under equipped cosmetic palette (no App reference; compile-cycle avoidance).
- `aadu_puli.gd` / `solah_seedi.gd` / `nine_mens_morris.gd` — pass `App.content.board_skin("<game-key>")` to `apply_board_skin`.
- `game_card.gd` — draws `App.content.card_texture(...)` over procedural art; subscribes `asset_ready → queue_redraw`.
- `game_selection.gd` — `_apply_display_order()` reorders cards by manifest displayOrder; re-runs on `manifest_changed`.
- `game_entry.gd` — tier cards get published color, description, and `_TierArt` texture.
- `menu_background.gd` — draws `home_texture()` full-bleed when available; else procedural scene.

---

## Tests & Gates

| Gate | Result |
|---|---|
| Server `npx tsc --noEmit` | ✅ clean |
| Server `npx eslint src/** test/**` | ✅ clean |
| Server `npm run build` | ✅ OK |
| Server Jest (`TEST_DATABASE_URL=... npx jest --runInBand`) | ✅ **37 suites / 494 tests pass** |
| Prisma validate | ✅ no drift |
| Prisma migrate diff (shadow DB `aatamgt_shadow_e2e`) | ✅ "No difference detected" |
| Angular `ng build` | ✅ green (13.2 s) |
| Godot `tests/validate.gd` | ✅ **682 checks, 0 failures** (baseline 639) |
| Godot `tests/phase_e/content_e2e.gd` | ✅ **9 checks, 0 failures** (published manifest v2) |
| Secret sweep (docs / scripts / tests) | ✅ no live credentials |

---

## Evidence

**Screenshots (5 tabs):**  
`builds/admin-19-content-games.png` · `admin-20-content-assets.png` · `admin-21-content-tiers.png` · `admin-22-content-board.png` · `admin-23-content-publish.png`

**E2E run:** `scripts/run_phase_e_e2e.sh` → boots HTTPS :3443 (local DB), seeds board theme + tier display via Prisma, logs in (`identifier`) + `POST /api/v1/admin/content/publish`, clears Godot cache, runs `content_e2e.gd` → exit 0, `CONTENT E2E: 9 checks, 0 failures`, `published manifest version 2`.

**Dev fixtures:** admin / `Password123!`, phasec_mod / `Password123!`, e2e admin `phase_e_admin` / `AdminPass123!`.

---

## Limitations

- **No server-side thumbnails.** Sharp is intentionally out of scope; clients download full-resolution assets. If thumbnails are needed later, add a separate worker/service rather than coupling it to the API process.
- **Single-region storage.** The S3 driver has no replication or lifecycle policies; enable those on the bucket itself.
- **Manifest checksum is server-computed.** Clients treat the inner checksum as an opaque change-detection token (key order differs across implementations); asset downloads are still sha256-verified against the per-asset checksum.

---

## Deployment steps

1. Set `ASSET_STORAGE_DRIVER`, `ASSET_STORAGE_LOCAL_ROOT`, `ASSET_MAX_UPLOAD_BYTES` (and `ASSET_S3_*` if using S3).
2. Run `npx prisma migrate deploy` against the target DB.
3. Restart the NestJS server.
4. Admins sign in to `/content`, upload assets, set board themes / tier display fields, then click **Publish now**.
5. Clients pick up the new version on their next manifest poll; asset files are content-addressed and never change under an existing checksum.

---

**Phase E complete.** Do not commit unless explicitly told.
