#!/usr/bin/env bash
# Phase 13 end-to-end runner: boots the NestJS backend over HTTPS
# with the dev store simulator (IAP_DEV_STORE), then drives the
# Godot client's purchase flow — catalog with store prices, a coin
# pack bought through the shop screen, duplicate/garbage token
# refusal, Royal Pass activation + restore, and store refund/revocation
# notifications — against it.
#
# Usage: scripts/run_phase13_e2e.sh
# Exit code 0 = backend built, server healthy, all client checks passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
PORT="${AATAMGT_E2E_PORT:-3443}"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
SERVER_LOG="$(mktemp /tmp/aatamgt_phase13_server.XXXXXX)"
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
	# Relaxed global limits (the suite registers and purchases in bursts).
	export THROTTLE_LIMIT=1000
	export AUTH_THROTTLE_LIMIT=100
	# Dev store simulator: the shop's purchase pipeline needs it.
	export IAP_DEV_STORE=true
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

APP_DATA="$HOME/Library/Application Support/Godot/app_userdata/AATAMGT"
echo "== clearing stored client session and offline game saves"
rm -f "$APP_DATA/session.json"
rm -f "$APP_DATA/aadu_puli_save.json"
rm -f "$APP_DATA/solah_seedi_save.json"
rm -f "$APP_DATA/nine_mens_morris_save.json"

echo "== running Godot phase 13 e2e"
cd "$ROOT"
AATAMGT_API_URL="https://127.0.0.1:$PORT" \
AATAMGT_CA_CERT="$CERT" \
"$GODOT_BIN" --headless --path . -s res://tests/phase13/purchases_e2e.gd
