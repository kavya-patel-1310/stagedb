#!/usr/bin/env bash
# Race test: N separate database sessions try to book the SAME two seats at the
# same instant (synchronised with pg_sleep_until). Exactly one must win; every
# other session must get TK409 and leave nothing behind.
# Usage: tests/concurrency_test.sh [clients]      (connection via PG* env vars)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${TEST_DB:-stagedb_race}"
N="${1:-50}"
PSQL=(psql -X -q -t -A -d "$DB")

"$ROOT/scripts/reset_db.sh" "$DB" >/dev/null
"${PSQL[@]}" -v ON_ERROR_STOP=1 -f "$ROOT/tests/fixtures.sql" >/dev/null
"${PSQL[@]}" -c "INSERT INTO ticketing.customers (email, full_name)
                 SELECT 'racer' || g || '@test.example', 'Racer ' || g FROM generate_series(1, $N) g" >/dev/null

START="$("${PSQL[@]}" -c "SELECT (clock_timestamp() + interval '2 seconds')::text")"
OUT="$(mktemp -d)"

for i in $(seq 1 "$N"); do
    cust=$((i + 3))
    (
        "${PSQL[@]}" -c "SELECT pg_sleep_until('$START');" >/dev/null
        if "${PSQL[@]}" -c "SELECT ticketing.reserve_seats($cust, 1, ARRAY[1,2]::bigint[])" >/dev/null 2>"$OUT/$i.err"; then
            echo won > "$OUT/$i.res"
        elif grep -q 'no longer available' "$OUT/$i.err"; then
            echo lost > "$OUT/$i.res"
        else
            echo error > "$OUT/$i.res"
        fi
    ) &
done
wait

won=$(cat "$OUT"/*.res | grep -cx won   || true)
lost=$(cat "$OUT"/*.res | grep -cx lost  || true)
errs=$(cat "$OUT"/*.res | grep -cx error || true)
[[ $errs -gt 0 ]] && { echo "Unexpected errors:"; cat "$OUT"/*.err | sort | uniq -c | head; }
active=$("${PSQL[@]}" -c "SELECT count(*) FROM ticketing.tickets WHERE event_id = 1 AND status IN ('reserved','issued')")
orders=$("${PSQL[@]}" -c "SELECT count(*) FROM ticketing.orders WHERE event_id = 1")
rm -rf "$OUT"

echo "clients=$N  won=$won  lost(TK409)=$lost  other_errors=$errs  active_tickets=$active  orders=$orders"
if [[ $won -eq 1 && $lost -eq $((N - 1)) && $errs -eq 0 && $active -eq 2 && $orders -eq 1 ]]; then
    echo "PASS: exactly one session won the seats; no double booking, no orphaned orders"
else
    echo "FAIL: concurrency invariant violated"; exit 1
fi
