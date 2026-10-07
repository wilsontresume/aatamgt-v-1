#!/usr/bin/env bash
# Generates a self-signed TLS certificate for local HTTPS development/e2e.
# The private key never leaves server/dev-certs (gitignored) and is never
# referenced by the Godot project.
set -euo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)/dev-certs"
CERT="$DIR/dev-cert.pem"
KEY="$DIR/dev-key.pem"

mkdir -p "$DIR"

if [ -f "$CERT" ] && [ -f "$KEY" ]; then
  echo "dev certificate already present: $CERT"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout "$KEY" -out "$CERT" \
  -subj "/CN=localhost" \
  -addext "subjectAltName=DNS:localhost,IP:127.0.0.1" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment,keyCertSign"

chmod 600 "$KEY"
echo "wrote $CERT and $KEY"
