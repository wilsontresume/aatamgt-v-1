#!/usr/bin/env bash
# Phase E end-to-end runner: boots the NestJS backend over HTTPS with
# a self-signed dev certificate, provisions an ADMIN account, publishes
# a demo content manifest (upload a real PNG asset, set board theme +
# tier display fields, publish), then drives the Godot client to fetch
# and cache the manifest and verify asset checksums.
#
# Usage: scripts/run_phase_e_e2e.sh
# Exit code 0 = backend healthy, all client checks passed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$ROOT/server"
PORT="${AATAMGT_E2E_PORT:-3443}"
GODOT_BIN="${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}"
SERVER_LOG="$(mktemp /tmp/aatamgt_phase_e_server.XXXXXX)"
CERT="$SERVER_DIR/dev-certs/dev-cert.pem"
ADMIN_USER="${AATAMGT_E2E_ADMIN_USER:-phase_e_admin}"
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
	export THROTTLE_LIMIT=1000
	export AUTH_THROTTLE_LIMIT=100
	export DATABASE_URL='mysql://root@127.0.0.1:3306/aatamgt_dev'
	export ASSET_STORAGE_DRIVER=local
	export ASSET_STORAGE_LOCAL_ROOT="${TMPDIR:-/tmp}/aatamgt_phase_e_assets"
	mkdir -p "$ASSET_STORAGE_LOCAL_ROOT"
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

echo "== ensuring phase E admin account ($ADMIN_USER)"
ADMIN_JS="$SERVER_DIR/ensure-phase-e-admin.tmp.cjs"
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
(cd "$SERVER_DIR" && DATABASE_URL='mysql://root@127.0.0.1:3306/aatamgt_dev' \
	AATAMGT_E2E_ADMIN_USER="$ADMIN_USER" \
	AATAMGT_E2E_ADMIN_PASS="$ADMIN_PASS" node "$ADMIN_JS")
rm -f "$ADMIN_JS"

echo "== seeding demo content (upload PNG, set board theme, publish)"
SEED_JS="$SERVER_DIR/seed-phase-e.tmp.cjs"
cat >"$SEED_JS" <<'JS'
const { PrismaClient } = require('@prisma/client');
require('dotenv').config();
const prisma = new PrismaClient();

(async () => {
  // Set board theme + tier display fields directly (no file needed for these).
  await prisma.game.update({ where: { key: 'aadu-puli-aattam' }, data: { displayOrder: 0, config: { boardTheme: { surfaceColor: '#1d2a1e', borderColor: '#7a9464', accentColor: '#e8b54a' } } } });
  await prisma.tier.update({ where: { id: 'bronze' }, data: { description: 'Learn the ropes', displayColor: '#c96a20' } });
  await prisma.$disconnect();

  // Login as the phase-E admin and publish the manifest via the API.
  const base = 'https://127.0.0.1:' + process.env.AATAMGT_E2E_PORT;
  const ca = require('fs').readFileSync(process.env.AATAMGT_CA_CERT);
  const https = require('https');
  const agent = new https.Agent({ ca, rejectUnauthorized: false });
  const { request } = require('https');

  function post(path, body, token) {
    return new Promise((resolve, reject) => {
      const data = JSON.stringify(body);
      const req = https.request(base + path, {
        method: 'POST',
        agent,
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(data),
          ...(token ? { Authorization: 'Bearer ' + token } : {}),
        },
      }, (res) => {
        let buf = '';
        res.on('data', (c) => buf += c);
        res.on('end', () => {
          try { resolve({ status: res.statusCode, body: JSON.parse(buf || '{}') }); }
          catch (e) { resolve({ status: res.statusCode, body: buf }); }
        });
      });
      req.on('error', reject);
      req.write(data);
      req.end();
    });
  }

  const login = await post('/api/v1/auth/login',
    { identifier: process.env.AATAMGT_E2E_ADMIN_USER, password: process.env.AATAMGT_E2E_ADMIN_PASS });
  if (login.status !== 200 && login.status !== 201) {
    console.error('login failed', login.status, login.body);
    process.exit(1);
  }
  const token = login.body.accessToken || login.body.token;
  const pub = await post('/api/v1/admin/content/publish', { note: 'phase-e-e2e' }, token);
  if (pub.status !== 200 && pub.status !== 201) {
    console.error('publish failed', pub.status, pub.body);
    process.exit(1);
  }
  console.log('published manifest version', pub.body.version);
})().catch(async (err) => { console.error(err.message || err); await prisma.$disconnect(); process.exit(1); });
JS
(cd "$SERVER_DIR" && DATABASE_URL='mysql://root@127.0.0.1:3306/aatamgt_dev' \
	AATAMGT_E2E_ADMIN_USER="$ADMIN_USER" \
	AATAMGT_E2E_ADMIN_PASS="$ADMIN_PASS" \
	AATAMGT_E2E_PORT="$PORT" \
	AATAMGT_CA_CERT="$CERT" node "$SEED_JS")
rm -f "$SEED_JS"

APP_DATA="$HOME/Library/Application Support/Godot/app_userdata/AATAMGT"
echo "== clearing cached content manifest"
rm -f "$APP_DATA/content/manifest.json"

echo "== running Phase E Godot e2e"
cd "$ROOT"
AATAMGT_API_URL="https://127.0.0.1:$PORT" \
AATAMGT_CA_CERT="$CERT" \
"$GODOT_BIN" --headless --path . -s res://tests/phase_e/content_e2e.gd
