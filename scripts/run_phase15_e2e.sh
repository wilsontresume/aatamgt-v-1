#!/usr/bin/env bash
# Phase 15 end-to-end runner: boots the NestJS backend over HTTPS with
# a self-signed dev certificate (IAP_DEV_STORE enabled), provisions the
# e2e admin account (ADMIN role in aatamgt_dev), then drives the Godot
# admin dashboard against it — staff gating, player search with
# suspend/ban/unban, game status filters with an operator finalisation,
# economy views from a real dev-store purchase, cosmetic price and
# enable/disable edits, runtime config overrides observed end-to-end,
# and the audit trail.
#
# Usage: scripts/run_phase15_e2e.sh
# Exit code 0 = backend built, server healthy, all client checks passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
PORT="${AATAMGT_E2E_PORT:-3443}"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
SERVER_LOG="$(mktemp /tmp/aatamgt_phase15_server.XXXXXX)"
CERT="$SERVER_DIR/dev-certs/dev-cert.pem"
ADMIN_USER="${AATAMGT_E2E_ADMIN_USER:-phase15_admin}"
ADMIN_PASS="${AATAMGT_E2E_ADMIN_PASS:-AdminPass123!}"

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
	# Relaxed global limits (the suite registers and acts in bursts).
	export THROTTLE_LIMIT=1000
	export AUTH_THROTTLE_LIMIT=100
	# Dev store simulator: the economy flow runs a real purchase.
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

echo "== ensuring e2e admin account ($ADMIN_USER)"
ADMIN_JS="$SERVER_DIR/ensure-phase15-admin.tmp.cjs"
cat >"$ADMIN_JS" <<'JS'
const { PrismaClient } = require('@prisma/client');
const bcrypt = require('bcryptjs');
require('dotenv').config();

const username = process.env.AATAMGT_E2E_ADMIN_USER;
const password = process.env.AATAMGT_E2E_ADMIN_PASS;
const prisma = new PrismaClient();

(async () => {
  const passwordHash = await bcrypt.hash(password, 10);
  const existing = await prisma.user.findUnique({ where: { username } });
  let user;
  if (existing) {
    user = await prisma.user.update({
      where: { id: existing.id },
      data: { passwordHash, role: 'ADMIN', status: 'ACTIVE', deletedAt: null },
    });
  } else {
    user = await prisma.user.create({
      data: {
        username,
        passwordHash,
        role: 'ADMIN',
        status: 'ACTIVE',
        profile: { create: { displayName: username } },
        wallets: { create: { currency: 'COIN', balance: 0 } },
      },
    });
  }
  process.stdout.write(`admin ready: ${user.username} (${user.id})\n`);
  await prisma.$disconnect();
})().catch(async (err) => {
  console.error(err);
  await prisma.$disconnect();
  process.exit(1);
});
JS
(cd "$SERVER_DIR" && AATAMGT_E2E_ADMIN_USER="$ADMIN_USER" \
	AATAMGT_E2E_ADMIN_PASS="$ADMIN_PASS" node "$ADMIN_JS")
rm -f "$ADMIN_JS"

APP_DATA="$HOME/Library/Application Support/Godot/app_userdata/AATAMGT"
echo "== clearing stored client session and offline game saves"
rm -f "$APP_DATA/session.json"
rm -f "$APP_DATA/aadu_puli_save.json"
rm -f "$APP_DATA/solah_seedi_save.json"
rm -f "$APP_DATA/nine_mens_morris_save.json"

echo "== running Godot phase 15 e2e"
cd "$ROOT"
AATAMGT_API_URL="https://127.0.0.1:$PORT" \
AATAMGT_CA_CERT="$CERT" \
AATAMGT_E2E_ADMIN_USER="$ADMIN_USER" \
AATAMGT_E2E_ADMIN_PASS="$ADMIN_PASS" \
"$GODOT_BIN" --headless --path . -s res://tests/phase15/admin_e2e.gd
