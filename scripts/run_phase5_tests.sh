#!/usr/bin/env bash
# Phase 5 runner: executes the Aadu Puli Aattam AI test suite in headless
# Godot. No server, network or UI involved — the search is pure and
# time-sliced.
#
# Usage: scripts/run_phase5_tests.sh
# Exit code 0 = every AI check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== clearing saved Aadu Puli game"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/aadu_puli_save.json"

echo "== running Aadu Puli AI tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase5/aadu_puli_ai_validate.gd
