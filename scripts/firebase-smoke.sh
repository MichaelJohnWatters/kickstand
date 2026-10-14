#!/usr/bin/env bash
# Smoke-test a real Firebase config: boot the server against FIREBASE_PROJECT_ID
# + GOOGLE_APPLICATION_CREDENTIALS on a throwaway DB and confirm it comes up
# firebase-enabled (production credentials) and ready. Proves the project id +
# service-account creds load — the common misconfig. Full token verification is
# exercised by a real login (see deploy/firebase-setup.md).
#
# Usage:
#   FIREBASE_PROJECT_ID=... GOOGLE_APPLICATION_CREDENTIALS=/abs/sa.json \
#     scripts/firebase-smoke.sh
set -euo pipefail

: "${FIREBASE_PROJECT_ID:?set FIREBASE_PROJECT_ID}"
: "${GOOGLE_APPLICATION_CREDENTIALS:?set GOOGLE_APPLICATION_CREDENTIALS}"
if [ ! -r "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "FAIL: GOOGLE_APPLICATION_CREDENTIALS not readable: $GOOGLE_APPLICATION_CREDENTIALS" >&2
  exit 1
fi
# The emulator env var would short-circuit real credentials — refuse to smoke
# against it.
if [ -n "${FIREBASE_AUTH_EMULATOR_HOST:-}" ]; then
  echo "FAIL: FIREBASE_AUTH_EMULATOR_HOST is set — unset it to smoke the real project" >&2
  exit 1
fi

PORT="${PORT:-8799}"
workdir="$(mktemp -d)"
log="$workdir/server.log"
bin="$workdir/server"

cleanup() { [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null || true; rm -rf "$workdir"; }
trap cleanup EXIT

echo "Building server..."
go build -o "$bin" ./cmd/server

echo "Booting on :$PORT against Firebase project '$FIREBASE_PROJECT_ID' (throwaway DB)..."
"$bin" -addr ":$PORT" -dsn "$workdir/smoke.db" -reminders-interval 0 -email-interval 0 >"$log" 2>&1 &
pid=$!

ready=0
for _ in $(seq 1 30); do
  if curl -fsS "http://localhost:$PORT/readyz" >/dev/null 2>&1; then ready=1; break; fi
  if ! kill -0 "$pid" 2>/dev/null; then break; fi   # server exited (e.g. bad creds)
  sleep 0.5
done

if [ "$ready" != 1 ]; then
  echo "FAIL: server did not become ready. Log:" >&2
  cat "$log" >&2
  exit 1
fi

if grep -q "firebase enabled (production credentials)" "$log"; then
  echo "✓ /readyz OK and Firebase enabled (production credentials)"
else
  echo "FAIL: server is ready but Firebase is NOT in production mode. Log:" >&2
  cat "$log" >&2
  exit 1
fi
