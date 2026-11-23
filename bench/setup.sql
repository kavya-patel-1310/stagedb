-- Benchmark harness: a driver function that simulates one checkout attempt
-- (pick an on-sale event, pick 2 adjacent seats, hold them, pay 85% of the time).
-- Seat conflicts are expected under contention and are counted, not errors.
SET search_path = ticketing, public;
SET client_min_messages = warning;

DROP SCHEMA IF EXISTS bench CASCADE;
CREATE SCHEMA bench;

CREATE TABLE bench.targets AS
SELECT e.event_id, array_agg(s.seat_id ORDER BY s.section_id, s.row_label, s.seat_number) AS seat_ids
  FROM events e JOIN seats s USING (venue_id)
 WHERE e.status = 'on_sale' AND e.starts_at > now()
 GROUP BY e.event_id;
ALTER TABLE bench.targets ADD COLUMN n serial;

CREATE TABLE bench.outcomes (outcome text PRIMARY KEY, n bigint NOT NULL DEFAULT 0);
CREATE UNLOGGED TABLE bench.log (outcome text NOT NULL);

CREATE FUNCTION bench.checkout(p_customer bigint, p_pick int) RETURNS text
LANGUAGE plpgsql AS $$
DECLARE
    t      bench.targets%ROWTYPE;
    i      int;
    v_order bigint;
    v_total bigint;
    v_out  text;
BEGIN
    SELECT * INTO t FROM bench.targets WHERE n = 1 + p_pick % (SELECT count(*) FROM bench.targets);
    i := 1 + floor(random() * (cardinality(t.seat_ids) - 1))::int;
    BEGIN
        v_order := ticketing.reserve_seats(p_customer, t.event_id, ARRAY[t.seat_ids[i], t.seat_ids[i + 1]]);
        IF random() < 0.85 THEN
            SELECT total_cents INTO v_total FROM ticketing.orders WHERE order_id = v_order;
            PERFORM ticketing.confirm_payment(v_order, v_total, 'stripe', 'bench_' || v_order);
            v_out := 'paid';
        ELSE
            v_out := 'held';
        END IF;
    EXCEPTION
        WHEN SQLSTATE 'TK409' THEN v_out := 'seat_taken';
        WHEN SQLSTATE 'TK004' THEN v_out := 'customer_limit';
    END;
    INSERT INTO bench.log VALUES (v_out);
    RETURN v_out;
END $$;
