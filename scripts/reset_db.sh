#!/usr/bin/env bash
# Drops and recreates the database, then loads every migration in order.
# Usage: scripts/reset_db.sh [dbname]        (connection via standard PG* env vars)
set -euo pipefail

DB="${1:-${PGDATABASE:-stagedb}}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PSQL=(psql -X -q -v ON_ERROR_STOP=1)

"${PSQL[@]}" -d postgres -c "SET client_min_messages = warning" -c "DROP DATABASE IF EXISTS \"$DB\" WITH (FORCE)" -c "CREATE DATABASE \"$DB\""

for f in "$ROOT"/sql/[0-9][0-9]_*.sql; do
    echo "  applying $(basename "$f")"
    "${PSQL[@]}" -d "$DB" -f "$f"
done
echo "Schema ready in database \"$DB\"."
