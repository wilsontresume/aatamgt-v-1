#!/usr/bin/env bash
# Phase 14 runner: executes the competitive ranking offline suite in
# headless Godot. No server involved — REST flows are covered by
# tests/phase14/rankings_e2e.gd and server/test/integration.
#
# Usage: scripts/run_phase14_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== running Phase 14 competitive ranking (offline) tests"
cd "$ROOT"
unset AATAMGT_API_URL || true
"$GODOT_BIN" --headless --path . -s res://tests/phase14/ranking_validate.gd
