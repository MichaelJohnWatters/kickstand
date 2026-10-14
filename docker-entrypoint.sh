#!/bin/sh
# Container entrypoint. The server migrates the DB on boot, so this only wraps
# it with Litestream when configured.
#
# With Litestream (LITESTREAM_BUCKET set): restore the DB from object storage if
# the volume is empty (fresh machine / lost volume), then serve *under*
# litestream so every write is streamed to the backup. Without it: just serve
# (dev / backups-not-yet-configured).
set -e

DB="${DB_PATH:-/data/kickstand.db}"
ADDR="${ADDR:-:8765}"
UPLOADS="${UPLOADS_DIR:-/data/uploads}"
LS_CONFIG="/etc/litestream.yml"

if [ -n "${LITESTREAM_BUCKET:-}" ]; then
  # No-op on a brand-new deploy with no backup yet.
  litestream restore -if-db-not-exists -if-replica-exists -config "$LS_CONFIG" "$DB"
  exec litestream replicate -config "$LS_CONFIG" \
    -exec "server -addr $ADDR -dsn $DB -uploads-dir $UPLOADS"
else
  exec server -addr "$ADDR" -dsn "$DB" -uploads-dir "$UPLOADS"
fi
