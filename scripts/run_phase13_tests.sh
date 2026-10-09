#!/usr/bin/env bash
# Phase 13 runner: executes the in-app purchase offline suite in
# headless Godot. No server involved — purchase flows are covered by
# tests/phase13/purchases_e2e.gd and server/test/integration.
#
# Usage: scripts/run_phase13_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== running Phase 13 in-app purchases (offline) tests"
cd "$ROOT"
unset AATAMGT_API_URL || true
"$GODOT_BIN" --headless --path . -s res://tests/phase13/purchase_validate.gd
