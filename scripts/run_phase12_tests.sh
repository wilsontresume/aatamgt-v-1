#!/usr/bin/env bash
# Phase 12 runner: executes the cosmetic inventory offline suite in
# headless Godot. No server involved — REST flows are covered by
# tests/phase12/cosmetics_e2e.gd and server/test/integration.
#
# Usage: scripts/run_phase12_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== running Phase 12 cosmetic inventory (offline) tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase12/cosmetic_validate.gd
