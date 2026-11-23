-- =============================================================================
-- StageDB · scripts/demo.sql — a guided tour of the booking API.
-- Runs in a transaction that is rolled back, so the database is left unchanged.
--     psql -d stagedb -f scripts/demo.sql
-- =============================================================================
\set ON_ERROR_STOP on
\pset footer off
SET search_path = ticketing, public;
BEGIN;

SELECT event_id AS demo_event, venue_id
  FROM events WHERE status = 'on_sale' AND starts_at > now() + interval '7 days'
 ORDER BY starts_at LIMIT 1 \gset

\echo '\n1) An upcoming event and the first few open seats'
SELECT event_id, title, venue, starts_at::date, sellable_seats, tickets_sold, sell_through_pct
  FROM v_event_sales WHERE event_id = :demo_event;
SELECT * FROM available_seats(:demo_event) LIMIT 4;

SELECT array_agg(seat_id) AS seats FROM (SELECT seat_id FROM available_seats(:demo_event) LIMIT 2) s \gset

\echo '\n2) Customer 101 holds two seats for 10 minutes'
SELECT reserve_seats(101, :demo_event, :'seats'::bigint[]) AS order_id \gset
SELECT order_id, status, total_cents, expires_at - now() AS hold_remaining FROM orders WHERE order_id = :order_id;

\echo '\n3) Customer 202 tries to grab the same seats -> rejected (TK409)'
SAVEPOINT s1;
\set ON_ERROR_STOP off
SELECT reserve_seats(202, :demo_event, :'seats'::bigint[]);
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT s1;

\echo '\n4) Payment webhook arrives (and is retried: idempotent, same payment_id)'
SELECT total_cents AS total FROM orders WHERE order_id = :order_id \gset
SELECT confirm_payment(:order_id, :total, 'stripe', 'pi_demo_' || :order_id) AS payment_id;
SELECT confirm_payment(:order_id, :total, 'stripe', 'pi_demo_' || :order_id) AS payment_id_on_retry;
SELECT t.ticket_id, t.status, t.ticket_code FROM tickets t WHERE t.order_id = :order_id;

\echo '\n5) Gate scan: first scan admits, second is rejected (TK031)'
SELECT ticket_code AS code FROM tickets WHERE order_id = :order_id ORDER BY ticket_id LIMIT 1 \gset
SELECT * FROM check_in_ticket(:'code');
SAVEPOINT s2;
\set ON_ERROR_STOP off
SELECT * FROM check_in_ticket(:'code');
\set ON_ERROR_STOP on
ROLLBACK TO SAVEPOINT s2;

\echo '\n6) Full audit trail for the order'
SELECT operation,
       CASE operation WHEN 'I' THEN jsonb_build_object('status', new_row -> 'status', 'customer_id', new_row -> 'customer_id')
                      ELSE old_row END AS before,
       CASE operation WHEN 'I' THEN NULL ELSE new_row END AS after,
       changed_by
  FROM audit_log WHERE table_name = 'orders' AND row_pk = :order_id ORDER BY audit_id;

ROLLBACK;
\echo '\nDemo complete (all changes rolled back).'
