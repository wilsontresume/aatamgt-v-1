#!/usr/bin/env bash
# Phase 4 runner: executes the Aadu Puli Aattam rule-engine test suite in
# headless Godot. No server, network or UI involved — the engine is pure.
#
# Usage: scripts/run_phase4_tests.sh
# Exit code 0 = every engine check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== clearing saved Aadu Puli game"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/aadu_puli_save.json"

echo "== running Aadu Puli rule-engine tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase4/aadu_puli_validate.gd
