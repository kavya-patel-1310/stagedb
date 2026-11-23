#!/usr/bin/env bash
# Throughput benchmark of the full checkout path on the seeded dataset.
# Usage: bench/run_bench.sh [clients] [seconds]     (DB via PG* env vars; default "stagedb")
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DB="${PGDATABASE:-stagedb}"
C="${1:-32}"; T="${2:-30}"
PSQL=(psql -X -q -v ON_ERROR_STOP=1 -d "$DB")

"${PSQL[@]}" -f "$ROOT/bench/setup.sql" >/dev/null
echo "Running $C concurrent clients for ${T}s against $("${PSQL[@]}" -tAc 'SELECT count(*) FROM bench.targets') on-sale events..."
pgbench -n -d "$DB" -c "$C" -j "$(( C < 8 ? C : 8 ))" -T "$T" -f "$ROOT/bench/checkout.pgbench" 2>/dev/null \
    | grep -E 'number of transactions actually processed|latency average|tps ='

echo
echo "Outcomes:"
"${PSQL[@]}" -c "SELECT outcome, count(*) AS attempts, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
                 FROM bench.log GROUP BY 1 ORDER BY 2 DESC"
echo "Integrity check (must be 0 rows = no seat sold twice):"
"${PSQL[@]}" -c "SELECT event_id, seat_id, count(*) FROM ticketing.tickets
                 WHERE status IN ('reserved','issued') GROUP BY 1, 2 HAVING count(*) > 1"
echo "Order totals that disagree with their tickets (must be 0):"
"${PSQL[@]}" -tAc "SELECT count(*) FROM ticketing.orders o
                   WHERE o.total_cents <> (SELECT COALESCE(sum(price_cents),0) FROM ticketing.tickets t WHERE t.order_id = o.order_id)"
