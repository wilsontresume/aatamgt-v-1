#!/usr/bin/env bash
# Phase 10 runner: executes the Nine Men's Morris rule-engine and
# AI test suites in headless Godot. No server, network or UI involved —
# the engine is pure.
#
# Usage: scripts/run_phase10_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== clearing saved Nine Men's Morris game"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/nine_mens_morris_save.json"

echo "== running Nine Men's Morris rule-engine tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase10/morris_validate.gd

echo "== running Nine Men's Morris AI tests"
"$GODOT_BIN" --headless --path . -s res://tests/phase10/morris_ai_validate.gd
