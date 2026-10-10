#!/usr/bin/env bash
# Phase 15 runner: executes the admin dashboard offline suite in
# headless Godot. No server involved — REST flows are covered by
# tests/phase15/admin_e2e.gd and server/test/integration.
#
# Usage: scripts/run_phase15_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== running Phase 15 admin dashboard (offline) tests"
cd "$ROOT"
unset AATAMGT_API_URL || true
"$GODOT_BIN" --headless --path . -s res://tests/phase15/admin_validate.gd
