#!/usr/bin/env bash
# Phase 11 runner: executes the social (friends/challenges/history)
# offline suite in headless Godot. No server involved — REST flows are
# covered by tests/phase11/social_e2e.gd and server/test/integration.
#
# Usage: scripts/run_phase11_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== running Phase 11 social (offline) tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase11/social_validate.gd
