# Android UI Interaction and Authentication Workflow Audit — Final Report

**Date:** 2026-10-12
**Build:** `builds/aatamgt-debug.apk` (exported 15:31, arm64, `com.aatamgt.app`)
**Device:** Pixel_10a API 37 arm64 (swiftshader), native 1080x2424

---

## 1. Root Causes Found

### A. Buttons not responding to taps (primary)
`DialogRoot` in `scenes/main.tscn` was a full-screen `Control` on CanvasLayer 10 (above `ScreenLayer`) with Godot's default `mouse_filter = MOUSE_FILTER_STOP`. Even when `visible = false`, the node consumed every pointer event before it reached any screen button. **Every button in the app was dead on Android.**

### B. Host-side input injection (not an app bug)
`adb shell input tap` was broken on the emulator (Settings app also unresponsive) — fixed by `adb kill-server; adb start-server`, but `input tap` and `input keyevent` later produced phantom multi-taps (3–6 sibling events per single tap; one sequence ejected the app into system Settings). **Use `input motionevent DOWN x y` + `input motionevent UP x y` — clean, no phantoms.** This is a host/emulator tooling bug, not an app defect.

### C. Error/confirm dialog layout broken on Android
Two defects, both fixed:
1. **Autowrap label min-width = 1px on Android.** `Label` with `autowrap_mode = Word` measures min-width as 1px, so the layout system wraps to absurd heights (`title` min = (1, 537), `msg` min = (1, 1212) → panel min-height 1885 > viewport 1616). Fixed by setting `custom_minimum_size = Vector2(400, 0)` on `TitleLabel` and `MessageLabel` in both dialog scenes.
2. **Dialog root anchors never re-resolve after the surface-sized viewport arrives.** On Android the root `Control` stayed at (0, 0) with size 0x0 (full-rect preset resolved against a 0x0 parent at scene load). Fixed by: visibility cycle in `open()`; `_notification(NOTIFICATION_RESIZED)` → deferred `_resort()`; `_resort()` re-resolves `PRESET_FULL_RECT` when self < 1px and manually pins `$Center` offsets to the real size. Same guard now applied to `ui_confirm_dialog.gd`.

After fix, verified on device: `self=(720,1616) center=(720,1616) panel=(110,701)` — perfect centering; mins `panel=(500,214) title=(400,27) msg=(400,51)`.

### D. "Launches directly into gameplay" — does NOT reproduce
Traced path: `project.godot` main scene `res://scenes/main.tscn` → `main.gd._ready` → `App.navigation.go(&"splash")` → `splash_screen.gd` (bootstrap, 1.4 s minimum, bounded 3 s session restore, no stored session on fresh install) → `main_menu`. "Guest Player/Guest" labels are the local placeholder from `App.bootstrap()`. Guest-first design preserved; no auto-match anywhere. **No bug here** — fresh install correctly lands on the main menu as a guest.

---

## 2. Files Changed and Why

| File | Change | Reason |
|---|---|---|
| `scenes/main.tscn` | DialogRoot `mouse_filter = 2` (IGNORE) | Root cause A: overlay was eating all taps |
| `src/core/main.gd` | `NOTIFICATION_WM_GO_BACK_REQUEST` → `App.navigation.back()` / `quit()`; navigation debug log | Android hardware back support + flow evidence |
| `src/ui/components/ui_error_dialog.gd` | `_notification(RESIZED)` → `_resort()`; anchor re-resolve + Center pin; visibility cycle in `open()`; debug prints trimmed | Root cause C |
| `src/ui/components/ui_confirm_dialog.gd` | Same `_resort` guard as error dialog; visibility cycle in `open()` | Root cause C (same structure, same latent bug) |
| `scenes/components/error_dialog.tscn` | `custom_minimum_size = Vector2(400, 0)` on TitleLabel + MessageLabel | Root cause C: min-width 1px explosion |
| `scenes/components/confirm_dialog.tscn` | Same | Root cause C |
| `src/ui/screens/main_menu.gd` | `_log(label)` per button (debug-guarded) | Flow evidence |
| `src/ui/screens/auth_screen.gd` | Mode-switch / submit / result logs (debug-guarded; no tokens/passwords) | Auth-flow evidence |
| `src/ui/screens/splash_screen.gd` | Session-restore log | Startup-path evidence |
| `src/ui/screens/game_selection.gd` | Game-selected log | Navigation evidence |

---

## 3. App Flow Before vs After

**Before (broken):**
- Every button dead (DialogRoot overlay). Taps did nothing.
- `adb input tap` phantoms could eject app into Settings.
- Guest-login error dialog: panel stuck at top-left, overflowing viewport.

**After (verified on device with real taps + logcat):**
- Fresh install → splash (bootstrap) → main menu (guest). No auto-gameplay.
- PLAY → game selection → any game card → board renders (art, pieces, AI).
- Profile → Sign in → validation error shows a **perfectly centered** error dialog (panel 110,701 in 720x1616; screenshot `/tmp/audit_32_dialog_open.png`).
- Guest login → honest network error (`ok=false status=0 kind=1`), dialog centered.
- Hardware back (`keyevent 4` / `NOTIFICATION_WM_GO_BACK_REQUEST`) pops the nav stack (`navigate -> game_selection`, `navigate -> profile`).
- Morris board tap places a piece and the AI responds.

---

## 4. Preserved: Backend Endpoints and JWT Session Handling

- No changes to `src/core/net/backend_config.gd`, `src/core/net/api_client.gd`, or any endpoint URLs.
- JWT session flow unchanged: splash restore path, `AuthService`, token storage/refresh all untouched.
- Backend loopback-only HTTP policy unchanged (`https://127.0.0.1:3443`). Emulator cannot reach the host loopback — guest/sign-in return `kind=1 (NETWORK)` by design, not a regression.
- Guest-first local placeholder flow preserved exactly (no forced account creation).

---

## 5. Tests and Results

| Suite | Result |
|---|---|
| `tests/validate.gd` | **583 checks, 0 failures** |
| 11 offline game/feature runners (`phase4/5/9/10/11/12/13/14/15 *_validate.gd`) | **all pass, 0 failures** (AADU_PULI 104, AADU_PULI_AI 120, MORRIS 226, MORRIS_AI 121, COSMETIC 100, SOCIAL 88, SOLAH 164, SOLAH_AI 120, purchase 105, ranking 81, admin 86) |
| Godot import + export-debug | no `SCRIPT ERROR` / `Parse Error` / `FAIL` |
| APK bytecode check | `unzip -l` confirms fresh `.gdc` for `main`, both dialogs, screens (15:31 timestamps) |

---

## 6. Emulator Taps Verified (native 1080x2424)

| Action | Coordinates | Evidence |
|---|---|---|
| PLAY | (540, 961) | `UI: main menu 'PLAY' pressed` → `navigate -> game_selection` |
| Aadu Puli card | (540, 298) | `UI: game selected -> aadu_puli` → board + art |
| Solah Seedi card | (540, 509) | `UI: game selected -> solah_seedi` → fresh board |
| Morris card | (540, 719) | `UI: game selected -> nine_mens_morris` → board |
| In-app Back | (122, 78) | `navigate -> game_selection` |
| Profile | (540, 1075) | `navigate -> profile` ("Not signed in") |
| Sign in | (540, 504) | auth screen opens |
| Guest | (540, 751) | `guest login started` → `ok=false status=0 kind=1`; centered error dialog |
| Hardware back | `keyevent 4` | `navigate -> game_selection` / `navigate -> profile` |
| Morris board tap | piece placement | piece placed + AI responded |

Input method used: `input motionevent DOWN/UP` (phantom-free). `input tap` / `keyevent` produce phantom siblings on this emulator — documented above.

---

## 7. Remaining Manual Checks

1. **Backend auth success path on emulator** — not testable here (`127.0.0.1:3443` unreachable from AVD). Covered by desktop e2e (`tests/phase3/auth_e2e.gd` and prior e2e suite: 839/0). Manual check: run backend on host, connect emulator via `10.0.2.2` or reverse-tcp, sign in with a real account.
2. **Confirm dialog visual check on device** — code guard applied (same as error dialog) but no on-device screenshot of the confirm variant was captured.
3. **Real-device input** — phantom-tap behavior is emulator/adb specific; physical devices should be spot-checked with real finger taps.
4. **Jest UI suite** — 31/389 previously; unrelated to these fixes, not re-run.

---

## 8. Exact Rebuild / Run Commands

```bash
export PATH="/usr/local/bin:$PATH"
GODOT=/Applications/Godot.app/Contents/MacOS/Godot
ADB="$HOME/Library/Android/sdk/platform-tools/adb"

# Import + export
"$GODOT" --headless --path . --import
"$GODOT" --headless --path . --export-debug "Android"
# -> builds/aatamgt-debug.apk

# Install + launch
"$ADB" install -r builds/aatamgt-debug.apk
"$ADB" shell am start -n com.aatamgt.app/com.godot.game.GodotAppLauncher

# Clean taps (phantom-free)
"$ADB" shell input motionevent DOWN 540 961
"$ADB" shell input motionevent UP  540 961

# Flow evidence
"$ADB" logcat -d -s godot:I | grep -E "UI:|navigate"
```

Regression:
```bash
"$GODOT" --headless --path . --script tests/validate.gd
for f in tests/phase*/**/*_validate.gd; do "$GODOT" --headless --path . --script "$f"; done
```

---

## 9. Verification Artifacts

| Artifact | Path |
|---|---|
| Fresh-install main menu | `/tmp/audit_01_fresh_menu.png` |
| Game selection | `/tmp/audit_06_game_selection.png` |
| Solah Seedi fresh board | `/tmp/audit_07_solah.png` |
| Morris board + placed move | `/tmp/audit_12_morris.png`, `/tmp/audit_13_morris.png` |
| Aadu Puli board (art) | `/tmp/audit_16_aadu.png` |
| Profile (not signed in) | `/tmp/audit_19_profile.png` |
| Auth sign-in | `/tmp/audit_20_auth.png` |
| Validation error | `/tmp/audit_21_validation.png` |
| Register mode | `/tmp/audit_23_register.png` |
| **Fixed centered error dialog** | `/tmp/audit_32_dialog_open.png` |
| Debug APK | `builds/aatamgt-debug.apk` |

**Verdict:** All three real bugs (tap-eating overlay, dialog layout explosion, missing Android back handling) are root-caused, fixed, and verified on-device. The reported "direct launch into gameplay" does not reproduce — startup correctly lands on the main menu as guest. Full regression green (583 + 11 runners, 0 failures). No new features added; backend/auth contracts unchanged.
