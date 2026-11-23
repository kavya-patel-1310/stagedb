# Performance notes

All numbers come from PostgreSQL 16.15 with default settings, running on a **2-vCPU** Linux cloud VM. They use the seeded dataset (100k customers, 300 events, ~185k orders, ~306k tickets). Absolute figures depend on hardware. The point is the *shape*: index-backed lookups in milliseconds or less, and zero integrity violations under heavy concurrent load.

## Checkout throughput (pgbench)

`bench/run_bench.sh` drives the real API. Each transaction picks a random on-sale event and two adjacent seats, calls `reserve_seats`, then calls `confirm_payment` 85% of the time. Seats run out as the test goes on, so contention rises the whole time. That's deliberately close to a hot on-sale.

| Clients | Duration | Txns/sec | Avg latency | Attempts | Paid | Held | Seat already taken |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 32 | 30 s | **1,283** | 24.9 ms | 38,511 | 14,622 | 2,589 | 21,297 (55%) |
| 64 | 20 s | 1,402 | 45.6 ms | 28,052 | — | — | — |

After every run, the script checks two things:

```sql
-- no seat is active twice for the same event          → 0 rows
SELECT event_id, seat_id FROM tickets WHERE status IN ('reserved','issued')
 GROUP BY 1, 2 HAVING count(*) > 1;
-- every order total equals the sum of its tickets      → 0
```

Both have come back clean on every run.

## Race test

`tests/concurrency_test.sh` starts 50 separate `psql` sessions. They're synchronised with `pg_sleep_until()`, and all request the *same* two seats at the same instant:

```
clients=50  won=1  lost(TK409)=49  other_errors=0  active_tickets=2  orders=1
```

The losers' orders roll back completely. The function is atomic, so no order rows are left behind.

## Query plans

**Customer "my orders" page**: `ix_orders_customer_recent (customer_id, created_at DESC) INCLUDE (status, total_cents)`

```
Limit (actual time=0.218..0.221 rows=20)
  ->  Sort  Sort Key: created_at DESC
        ->  Bitmap Heap Scan on orders
              ->  Bitmap Index Scan on ix_orders_customer_recent
                    Index Cond: (customer_id = 42)
Execution Time: 0.276 ms
```

**Hold-expiry sweeper**: partial index `ix_orders_pending_expiry ... WHERE status = 'pending'`. It indexes only the few hundred pending orders out of 185k, so it stays tiny and fast however much order history piles up.

```
Bitmap Index Scan on ix_orders_pending_expiry (actual time=0.025..0.025 rows=248)
  Index Cond: (expires_at <= now())
Execution Time: 0.547 ms
```

**Audit history for one month**: partition pruning touches a single monthly partition.

```
EXPLAIN SELECT * FROM audit_log
 WHERE table_name = 'orders' AND row_pk = 5
   AND changed_at >= '2026-11-01' AND changed_at < '2026-12-01';

Seq Scan on audit_log_2026_11 audit_log
```

**Fuzzy event search**: GIN trigram index `ix_events_title_trgm`. With only 300 events the planner rightly prefers a sequential scan (0.2 ms). The index takes over as the table grows (shown here with `enable_seqscan = off`):

```
Bitmap Heap Scan on events
  ->  Bitmap Index Scan on ix_events_title_trgm
        Index Cond: (title ~~* '%lighthous%'::text)
```

**Seat map** (`available_seats`) for an ~800-seat event: **6 ms**.

## Seed performance

The whole dataset (~800k rows across 10 tables) is generated with set-based `INSERT ... SELECT` and `generate_series` (no row-by-row loops). It loads in about **25 seconds** with every FK, CHECK and unique constraint still enforced. Only the audit triggers are paused during the historical backfill.
