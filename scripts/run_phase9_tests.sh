#!/usr/bin/env bash
# Phase 9 runner: executes the Solah Seedi (16 Soldiers) rule-engine and
# AI test suites in headless Godot. No server, network or UI involved —
# the engine is pure.
#
# Usage: scripts/run_phase9_tests.sh
# Exit code 0 = every check passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"

echo "== clearing saved Solah Seedi game"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/solah_seedi_save.json"

echo "== running Solah Seedi rule-engine tests"
cd "$ROOT"
"$GODOT_BIN" --headless --path . -s res://tests/phase9/solah_seedi_validate.gd

echo "== running Solah Seedi AI tests"
"$GODOT_BIN" --headless --path . -s res://tests/phase9/solah_seedi_ai_validate.gd
