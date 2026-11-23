-- =============================================================================
-- StageDB · 06_security.sql
-- Principle of least privilege:
--   stagedb_app      : backend service. Reads tables, mutates ONLY via the API
--                      functions (no direct INSERT/UPDATE/DELETE).
--   stagedb_analyst  : BI / reporting. Reporting views only; no PII tables.
--   stagedb_customer : customer-facing read path (e.g. a "my tickets" API).
--                      Row-Level Security restricts it to its own rows via
--                      SET app.customer_id = '<id>'.
-- Roles are NOLOGIN groups; real logins are granted membership.
-- =============================================================================

SET search_path = ticketing, public;

DO $$
DECLARE r text;
BEGIN
    FOREACH r IN ARRAY ARRAY['stagedb_app', 'stagedb_analyst', 'stagedb_customer'] LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) THEN
            EXECUTE format('CREATE ROLE %I NOLOGIN', r);
        END IF;
    END LOOP;
END $$;

-- Start from zero
REVOKE ALL ON ALL TABLES    IN SCHEMA ticketing FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ticketing FROM PUBLIC;
REVOKE ALL ON SCHEMA ticketing FROM PUBLIC;

GRANT USAGE ON SCHEMA ticketing TO stagedb_app, stagedb_analyst, stagedb_customer;

-- Application service
GRANT SELECT ON ALL TABLES IN SCHEMA ticketing TO stagedb_app;
GRANT EXECUTE ON FUNCTION
    reserve_seats(bigint, bigint, bigint[], interval),
    confirm_payment(bigint, bigint, text, text),
    refund_order(bigint, text),
    cancel_event(bigint, text),
    expire_stale_orders(int),
    check_in_ticket(uuid),
    available_seats(bigint),
    complete_past_events(),
    refresh_reporting()
TO stagedb_app;

-- Analysts: aggregated, de-identified reporting only
GRANT SELECT ON v_event_sales, mv_daily_revenue TO stagedb_analyst;

-- Customers: own orders and tickets only, plus public catalogue data
GRANT SELECT ON orders, tickets TO stagedb_customer;
GRANT SELECT ON events, venues, sections, seats, price_tiers TO stagedb_customer;
GRANT EXECUTE ON FUNCTION available_seats(bigint) TO stagedb_customer;

ALTER TABLE orders  ENABLE ROW LEVEL SECURITY;
ALTER TABLE tickets ENABLE ROW LEVEL SECURITY;

-- The app service sees everything
CREATE POLICY app_all_orders  ON orders  FOR SELECT TO stagedb_app USING (true);
CREATE POLICY app_all_tickets ON tickets FOR SELECT TO stagedb_app USING (true);

-- A customer sees only their own rows. current_setting(..., true) returns NULL
-- when unset, so a session that forgets to identify itself sees nothing.
CREATE POLICY customer_own_orders ON orders FOR SELECT TO stagedb_customer
    USING (customer_id = NULLIF(current_setting('app.customer_id', true), '')::bigint);

CREATE POLICY customer_own_tickets ON tickets FOR SELECT TO stagedb_customer
    USING (EXISTS (SELECT 1 FROM orders o
                    WHERE o.order_id = tickets.order_id
                      AND o.customer_id = NULLIF(current_setting('app.customer_id', true), '')::bigint));

-- Functions and tables created later should not silently become public
ALTER DEFAULT PRIVILEGES IN SCHEMA ticketing REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
