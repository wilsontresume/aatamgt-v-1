# Main Menu Redesign + Login & Entry Flow — Completion Report

**Date:** 2026-10-12
**Build:** `builds/aatamgt-debug.apk` (exported 20:41, Godot 4.7.2, Android debug)
**Device:** Android Emulator — Pixel_10a API 37 (arm64), 1080×2424
**Backend:** local NestJS (`server/dist/main.js`, HTTPS :3443, dev cert, remote MySQL) reachable
from the emulator via `adb reverse tcp:3443 tcp:3443`.

---

## 1. What shipped

### 1.1 Colorful arcade main menu (replaces the plain dark menu)

| Region | Content |
|---|---|
| Header pill | Player avatar + name/role (real session), centered `UI/logo.png`, real coin balance pill |
| Carousel | 3 game cards (Solah Seedi / Aadu Puli Aattam / Nine Men's Morris) with per-game procedural artwork, gold glow on the selected card, page dots; selection persisted via `App.selected_game` |
| PLAY | Gold animated button + `CPUParticles2D` sparkles → opens the selected game's own mode-selection screen (`Vs AI / Hot seat / Online`) |
| Banners | Daily Rewards (blue, real `GET/POST /rewards/daily`) and Royal Pass (red → existing `shop` screen) |
| Features row | 8 vector-icon buttons: Profile, Shop, Settings, Friends, Inventory, History, Rankings, Admin (staff only) |
| Bottom nav | Home, Friends, Leaderboard, Profile, Store — existing destinations |
| Background | Procedural dusk-temple scene (`menu_background.gd`): gradient sky, treeline, lit path, lamps, floating petals, scene fade-in |

Wallet, rewards, player identity and staff visibility are all read from the live backend —
no hard-coded balances, no simulated data.

### 1.2 Login-first entry flow (Workflow change 1)

- Fresh install → **splash → login screen** (Home never opens before authentication).
- Google / Facebook buttons → honest *"… not configured"* dialogs, **no session created, never simulated**.
- Guest, username/password sign-in and registration use the existing NestJS auth APIs unchanged.
- Successful auth → navigates Home with a cleared back stack (`NavigationService.go_no_back` / `ROOT_SCREEN`).
- Relaunch → stored session restored on splash → Home.
- Sign out (Settings, with confirm dialog) or `signed_out` signal → login screen with no Back button.
- Session JSON is the single source of truth; expired/absent → login.

---

## 2. Files changed / added

**Menu (new):**
- `src/ui/menu/menu_background.gd`, `game_card.gd`, `menu_icon.gd`, `menu_icon_button.gd`, `menu_banner.gd`
- `scenes/components/game_card.tscn`, `menu_icon_button.tscn`, `menu_banner.tscn`
- `src/core/services/rewards_service.gd` (`App.rewards` — daily status/claim over existing endpoints)

**Menu (rewritten/edited):**
- `scenes/screens/main_menu.tscn`, `src/ui/screens/main_menu.gd`
- `src/ui/theme/app_theme.gd` (arcade palette + `PlayButton` / `MenuPanel` variations)
- `src/core/app.gd` (`selected_game` state, persisted per `save_local_setting`)

**Login flow:**
- `src/ui/screens/splash_screen.gd` (routes to `auth` when unauthenticated)
- `src/core/main.gd` (`signed_out` → `go_no_back(&"auth")`)
- `src/core/services/navigation_service.gd` (new `go_no_back()`)
- `src/ui/screens/auth_screen.gd`, `scenes/screens/auth_screen.tscn`
  (Google/Facebook buttons + setup-error dialogs, `_leave()` → ROOT screen,
  Back button hidden when history is empty, `_set_busy` covers social buttons)

**Build / platform fixes (found during emulator verification):**
- `export_presets.cfg` — `permissions/custom_permissions=PackedStringArray("android.permission.INTERNET")`
  *(the APK previously declared no INTERNET permission: every device-side request failed at `socket()`)*;
  `include_filter` ships `server/dev-certs/dev-cert.pem`, `exclude_filter` keeps `dev-key.pem` **out** of the APK.
- `src/core/net/backend_config.gd` — debug builds fall back to the bundled dev certificate so a device
  can trust a host-run dev backend (release builds keep the platform store only).
- `src/ui/screens/main_menu.gd` — daily banner formats amounts as integers (`+100 coins · Day 1`, was `100.0/1.0`).

**Tests updated for new node paths/labels:** `tests/validate.gd` (incl. splash→auth assertions),
`tests/phase11..15 *_validate.gd`, `tests/phase13..15 *_e2e.gd`, `tests/phase9/10 *_e2e.gd`.
All backend e2e tests authenticate before booting `main.tscn`, so they remain compatible with login-first.

---

## 3. Art, assets & licenses

| Asset | Source | License |
|---|---|---|
| `UI/logo.png`, `UI/Main Menu.png` | Project-owned (provided design reference) | Project assets |
| Menu background, 3 game-card illustrations, 20 UI icons, PLAY/banners | **Original procedural `_draw()` artwork** authored for this change — no external assets, no third-party art, no flattened screenshots | Project-owned |
| Arcade palette | Original color scheme inspired only by the referenced layout | — |

Nothing is embedded beyond `server/dev-certs/dev-cert.pem` (public dev certificate only — the
private key is excluded by `exclude_filter` and verified absent from the APK).

---

## 4. Emulator verification (all taps via `input motionevent DOWN/UP`)

| # | Flow | Result | Evidence |
|---|---|---|---|
| 1 | Fresh install → boot | `splash → auth` — login screen, no Back button | `/tmp/login_04_fresh.png` |
| 2 | Continue with Google | "Google Sign-In not configured … No session was created." | `/tmp/login_05_google.png` |
| 3 | Continue with Facebook | "Facebook Sign-In not configured … No session was created." | `/tmp/login_06_facebook.png` |
| 4 | Continue as guest (real backend) | `ok=true status=201` → `main_menu`, pill "Guest C3D9" | `/tmp/login_11_guest.png` |
| 5 | Force-stop + relaunch | `splash restoring stored session → authenticated=true → main_menu` | logcat 20:26:16 |
| 6 | Profile (server data) | real Player ID, Bronze/1000 ratings | `/tmp/login_12_restore.png` |
| 7 | Settings → Sign out → confirm | `session ended → navigate → auth` | `/tmp/login_16_after_signout.png` |
| 8 | Create account (`qaemu20261012`) | `auth register → ok=true status=201 → main_menu` | `/tmp/login_18_registered.png` |
| 9 | Password sign-in | `auth login → ok=true status=200 → main_menu` | logcat 20:35:42 |
| 10 | Daily Rewards claim | real `POST` → "Claimed! Come back tomorrow", wallet 0 → **1,100** | `/tmp/menu_04_claimed.png` |
| 11 | PLAY | `PLAY -> nine_mens_morris` → game screen (mode header + fresh board, Move 1, no match started) | `/tmp/menu_02_play.png` |
| 12 | Final APK fresh install + guest | `status=201 → main_menu`, banner "+100 coins · Day 1" | `/tmp/menu_05_final.png` |

Nav taps (Friends / Leaderboard / Back / Settings / card selection + persistence) were exercised
earlier in the session and logged `navigate -> …` correctly.

---

## 5. Tests & build

- `tests/validate.gd` — **593 checks, 0 failures** (includes splash→`auth` on fresh boot and
  "home never opens before authentication").
- 11 offline suites — **1,315 checks, 0 failures**
  (AADU 104+120, SOLAH 164+120, MORRIS 226+121, social 88, cosmetic 100, purchase 86, ranking 105, admin 81).
- **Total: 1,908 checks, 0 failures.**
- Note: the offline suites assert *offline* states — they must be run with the dev backend **stopped**
  (with it running, 15 offline-state checks fail by design; this is environmental, not a regression).
- APK export clean (only a benign Godot template warning about `mipmap/themed_icon`).

---

## 6. Known issues / remaining work

1. **adb phantom input (host bug):** `input motionevent` still occasionally replays queued taps that
   drift UI state (documented in `docs/ANDROID_UI_AUDIT_REPORT_2026-10-12.md`). Verify with a
   screenshot before every tap; not an app defect.
2. **INTERNET permission was missing from all previous APKs** — device networking never worked before
   this change; desktop e2e was unaffected. Fixed in `export_presets.cfg` (§2).
3. **APK size 37 MB:** `export_filter=all_resources` also packs `server/node_modules`/coverage files.
   Pre-existing; consider excluding `server/**` (except the dev cert) in a future pass.
4. **Google / Facebook sign-in** intentionally remain setup-error stubs until real OAuth credentials
   and backend endpoints are configured — no fake sessions, per spec.
5. **Daily banner state:** shows "Loading…" while the status request is in flight (≤6 s timeout,
   then "Offline — try again later"). The stale-looking captures in §4 were mid-flight screenshots.
6. **Logo rendering:** `UI/logo.png` carries a light matte that reads as a soft box on the dark
   header; acceptable but could be cleaned up in the source image.
7. E2E suites (phase 3/6/9–15) require the live backend; they were not re-run in this pass beyond the
   path updates — all offline suites were.
