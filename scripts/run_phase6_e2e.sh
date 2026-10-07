#!/usr/bin/env bash
# Phase 6 end-to-end runner: boots the NestJS backend over HTTPS with a
# self-signed dev certificate and a short turn clock, then drives the
# Godot client's online multiplayer against it with two players.
#
# Usage: scripts/run_phase6_e2e.sh
# Exit code 0 = backend built, server healthy, all client checks passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
PORT="${AATAMGT_E2E_PORT:-3443}"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
SERVER_LOG="$(mktemp /tmp/aatamgt_phase6_server.XXXXXX)"
CERT="$SERVER_DIR/dev-certs/dev-cert.pem"

cleanup() {
	if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
		kill "$SERVER_PID" 2>/dev/null || true
		wait "$SERVER_PID" 2>/dev/null || true
	fi
}
trap cleanup EXIT

echo "== building backend"
(cd "$SERVER_DIR" && npm run build >/dev/null)

echo "== ensuring dev certificate"
"$SERVER_DIR/scripts/dev-cert.sh"

echo "== starting HTTPS backend on :$PORT (log: $SERVER_LOG)"
(
	cd "$SERVER_DIR"
	export TLS_CERT_PATH="$SERVER_DIR/dev-certs/dev-cert.pem"
	export TLS_KEY_PATH="$SERVER_DIR/dev-certs/dev-key.pem"
	export PORT="$PORT"
	export LOG_LEVEL="${LOG_LEVEL:-error}"
	# Short clocks so the timeout section runs in seconds, not a minute.
	export MATCH_TURN_TIMEOUT_MS=6000
	export MATCH_DISCONNECT_GRACE_MS=5000
	exec node dist/main.js
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

healthy=0
for _ in $(seq 1 40); do
	if curl -skf "https://127.0.0.1:$PORT/health" >/dev/null 2>&1; then
		healthy=1
		break
	fi
	if ! kill -0 "$SERVER_PID" 2>/dev/null; then
		echo "backend exited early:"
		cat "$SERVER_LOG"
		exit 1
	fi
	sleep 0.5
done
if [ "$healthy" != "1" ]; then
	echo "backend never became healthy:"
	cat "$SERVER_LOG"
	exit 1
fi
echo "== backend healthy"

echo "== clearing stored client session and offline game save"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/session.json"
rm -f "$HOME/Library/Application Support/Godot/app_userdata/AATAMGT/aadu_puli_save.json"

echo "== running Godot phase 6 e2e"
cd "$ROOT"
AATAMGT_API_URL="https://127.0.0.1:$PORT" \
AATAMGT_CA_CERT="$CERT" \
"$GODOT_BIN" --headless --path . -s res://tests/phase6/online_e2e.gd
