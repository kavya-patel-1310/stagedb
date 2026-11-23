-- =============================================================================
-- StageDB · 03_functions.sql
-- The transactional API. Applications call these functions instead of writing
-- to tables directly; each one is a single atomic, concurrency-safe operation.
--
-- All are SECURITY DEFINER with a pinned search_path, so the application role
-- needs only EXECUTE privileges (see 05_security.sql).
--
-- Custom SQLSTATE error codes (stable contract for application code):
--   TK000 invalid argument          TK010 order already paid
--   TK002 event not on sale         TK011 order not payable (expired/cancelled)
--   TK003 event already started     TK012 payment amount mismatch
--   TK004 per-customer limit hit    TK020 refund not allowed
--   TK005 seat not sellable         TK030 ticket invalid for check-in
--   TK404 not found                 TK031 ticket already checked in
--   TK409 seat already taken        TK100/TK101 illegal state change (triggers)
-- =============================================================================

SET search_path = ticketing, public;

-- -----------------------------------------------------------------------------
-- Internal: expire one pending order whose hold has lapsed, releasing its seats.
-- Returns true if the order was expired by this call.
-- -----------------------------------------------------------------------------
CREATE FUNCTION _expire_order(p_order_id bigint)
RETURNS boolean
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
BEGIN
    UPDATE orders SET status = 'expired'
     WHERE order_id = p_order_id AND status = 'pending' AND expires_at <= now();
    IF NOT FOUND THEN
        RETURN false;
    END IF;
    UPDATE tickets SET status = 'released'
     WHERE order_id = p_order_id AND status = 'reserved';
    RETURN true;
END $$;

-- -----------------------------------------------------------------------------
-- reserve_seats: place a time-limited hold on specific seats.
--
-- Double-selling is made impossible by the partial unique index
-- uq_tickets_active_seat, not by application-level checks: if two sessions
-- race for the same seat, the second INSERT blocks on the first and then fails
-- with a unique violation, which is translated into TK409.
-- -----------------------------------------------------------------------------
CREATE FUNCTION reserve_seats(
    p_customer_id bigint,
    p_event_id    bigint,
    p_seat_ids    bigint[],
    p_hold        interval DEFAULT interval '10 minutes'
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_event      events%ROWTYPE;
    v_order_id   bigint;
    v_requested  int := COALESCE(cardinality(p_seat_ids), 0);
    v_inserted   int;
    v_held       int;
    v_stale      bigint;
    v_constraint text;
BEGIN
    IF v_requested = 0 THEN
        RAISE EXCEPTION 'At least one seat is required' USING ERRCODE = 'TK000';
    END IF;
    IF (SELECT count(DISTINCT s) FROM unnest(p_seat_ids) s) <> v_requested
       OR array_position(p_seat_ids, NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'Seat list contains duplicates or NULLs' USING ERRCODE = 'TK000';
    END IF;
    IF p_hold IS NULL OR p_hold <= interval '0' OR p_hold > interval '1 hour' THEN
        RAISE EXCEPTION 'Hold must be between 0 and 1 hour' USING ERRCODE = 'TK000';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Customer % not found', p_customer_id USING ERRCODE = 'TK404';
    END IF;

    -- FOR SHARE: many bookings may proceed in parallel, but the event cannot be
    -- cancelled or rescheduled underneath an in-flight booking.
    SELECT * INTO v_event FROM events WHERE event_id = p_event_id FOR SHARE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event % not found', p_event_id USING ERRCODE = 'TK404';
    END IF;
    IF v_event.status <> 'on_sale' THEN
        RAISE EXCEPTION 'Event % is not on sale (status: %)', p_event_id, v_event.status
              USING ERRCODE = 'TK002';
    END IF;
    IF v_event.starts_at <= now() THEN
        RAISE EXCEPTION 'Event % has already started', p_event_id USING ERRCODE = 'TK003';
    END IF;

    -- Per-customer cap across all of their active orders for this event.
    SELECT count(*) INTO v_held
      FROM tickets t JOIN orders o USING (order_id, event_id)
     WHERE o.customer_id = p_customer_id AND t.event_id = p_event_id
       AND t.status IN ('reserved', 'issued')
       AND NOT (o.status = 'pending' AND o.expires_at <= now());
    IF v_held + v_requested > v_event.max_tickets_per_customer THEN
        RAISE EXCEPTION 'Limit is % tickets per customer for this event (already holding %)',
              v_event.max_tickets_per_customer, v_held USING ERRCODE = 'TK004';
    END IF;

    -- Lazily expire any lapsed holds on the requested seats so they can be re-sold
    -- immediately, without waiting for the background sweeper.
    FOR v_stale IN
        SELECT DISTINCT t.order_id
          FROM tickets t JOIN orders o USING (order_id, event_id)
         WHERE t.event_id = p_event_id AND t.seat_id = ANY (p_seat_ids)
           AND t.status = 'reserved' AND o.status = 'pending' AND o.expires_at <= now()
    LOOP
        PERFORM _expire_order(v_stale);
    END LOOP;

    INSERT INTO orders (customer_id, event_id, expires_at)
    VALUES (p_customer_id, p_event_id, now() + p_hold)
    RETURNING order_id INTO v_order_id;

    BEGIN
        INSERT INTO tickets (order_id, event_id, venue_id, seat_id, price_cents)
        SELECT v_order_id, p_event_id, s.venue_id, s.seat_id, pt.price_cents
          FROM seats s
          JOIN price_tiers pt ON pt.event_id = p_event_id AND pt.section_id = s.section_id
         WHERE s.seat_id = ANY (p_seat_ids) AND s.venue_id = v_event.venue_id
         ORDER BY s.seat_id;                 -- consistent lock order prevents deadlocks
        GET DIAGNOSTICS v_inserted = ROW_COUNT;
    EXCEPTION WHEN unique_violation THEN
        GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME;
        IF v_constraint = 'uq_tickets_active_seat' THEN
            RAISE EXCEPTION 'One or more requested seats are no longer available'
                  USING ERRCODE = 'TK409';
        END IF;
        RAISE;
    END;

    IF v_inserted <> v_requested THEN
        RAISE EXCEPTION 'Some seats do not exist at this venue or are not on sale'
              USING ERRCODE = 'TK005';
    END IF;

    UPDATE orders
       SET total_cents = (SELECT sum(price_cents) FROM tickets WHERE order_id = v_order_id)
     WHERE order_id = v_order_id;

    RETURN v_order_id;
END $$;

-- -----------------------------------------------------------------------------
-- confirm_payment: capture payment for a pending order and issue tickets.
-- Idempotent on provider_ref, so a retried webhook returns the same payment.
-- -----------------------------------------------------------------------------
CREATE FUNCTION confirm_payment(
    p_order_id     bigint,
    p_amount_cents bigint,
    p_provider     text,
    p_provider_ref text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_order    orders%ROWTYPE;
    v_existing payments%ROWTYPE;
    v_payment  bigint;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found', p_order_id USING ERRCODE = 'TK404';
    END IF;

    -- Idempotency: the same provider reference replayed for the same order.
    SELECT * INTO v_existing FROM payments WHERE provider_ref = p_provider_ref;
    IF FOUND THEN
        IF v_existing.order_id = p_order_id AND v_existing.status = 'succeeded' THEN
            RETURN v_existing.payment_id;
        END IF;
        RAISE EXCEPTION 'Provider reference % already used', p_provider_ref USING ERRCODE = 'TK000';
    END IF;

    IF v_order.status = 'paid' THEN
        RAISE EXCEPTION 'Order % is already paid', p_order_id USING ERRCODE = 'TK010';
    END IF;
    IF v_order.status <> 'pending' OR v_order.expires_at <= now() THEN
        RAISE EXCEPTION 'Order % can no longer be paid (status: %, hold expires %)',
              p_order_id, v_order.status, v_order.expires_at USING ERRCODE = 'TK011';
    END IF;
    IF p_amount_cents IS DISTINCT FROM v_order.total_cents THEN
        RAISE EXCEPTION 'Payment amount % does not match order total %',
              p_amount_cents, v_order.total_cents USING ERRCODE = 'TK012';
    END IF;

    INSERT INTO payments (order_id, amount_cents, provider, provider_ref, status)
    VALUES (p_order_id, p_amount_cents, p_provider, p_provider_ref, 'succeeded')
    RETURNING payment_id INTO v_payment;

    UPDATE orders  SET status = 'paid', paid_at = now(), expires_at = NULL
     WHERE order_id = p_order_id;
    UPDATE tickets SET status = 'issued'
     WHERE order_id = p_order_id AND status = 'reserved';

    RETURN v_payment;
END $$;

-- -----------------------------------------------------------------------------
-- refund_order: full refund of a paid order; seats return to inventory.
-- Allowed before the event starts, or at any time if the event was cancelled.
-- -----------------------------------------------------------------------------
CREATE FUNCTION refund_order(p_order_id bigint, p_reason text)
RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_order   orders%ROWTYPE;
    v_event   events%ROWTYPE;
    v_payment payments%ROWTYPE;
    v_refund  bigint;
BEGIN
    SELECT * INTO v_order FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Order % not found', p_order_id USING ERRCODE = 'TK404';
    END IF;
    IF v_order.status <> 'paid' THEN
        RAISE EXCEPTION 'Only paid orders can be refunded (order % is %)', p_order_id, v_order.status
              USING ERRCODE = 'TK020';
    END IF;

    SELECT * INTO v_event FROM events WHERE event_id = v_order.event_id;
    IF v_event.status <> 'cancelled' AND v_event.starts_at <= now() THEN
        RAISE EXCEPTION 'Refunds close when the event starts' USING ERRCODE = 'TK020';
    END IF;
    IF EXISTS (SELECT 1 FROM tickets WHERE order_id = p_order_id AND checked_in_at IS NOT NULL) THEN
        RAISE EXCEPTION 'Order % has checked-in tickets', p_order_id USING ERRCODE = 'TK020';
    END IF;

    SELECT * INTO v_payment FROM payments
     WHERE order_id = p_order_id AND status = 'succeeded';

    INSERT INTO refunds (payment_id, amount_cents, reason)
    VALUES (v_payment.payment_id, v_payment.amount_cents, p_reason)
    RETURNING refund_id INTO v_refund;

    UPDATE orders  SET status = 'refunded' WHERE order_id = p_order_id;
    UPDATE tickets SET status = 'refunded' WHERE order_id = p_order_id AND status = 'issued';

    RETURN v_refund;
END $$;

-- -----------------------------------------------------------------------------
-- cancel_event: cancel an event, refund every paid order, void every hold.
-- Returns the number of orders refunded.
-- -----------------------------------------------------------------------------
CREATE FUNCTION cancel_event(p_event_id bigint, p_reason text)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_status   event_status;
    v_refunded int := 0;
    v_order    bigint;
BEGIN
    SELECT status INTO v_status FROM events WHERE event_id = p_event_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Event % not found', p_event_id USING ERRCODE = 'TK404';
    END IF;

    UPDATE events SET status = 'cancelled' WHERE event_id = p_event_id;  -- trigger validates

    WITH voided AS (
        UPDATE orders SET status = 'cancelled'
         WHERE event_id = p_event_id AND status = 'pending'
     RETURNING order_id
    )
    UPDATE tickets t SET status = 'released'
      FROM voided v WHERE t.order_id = v.order_id AND t.status = 'reserved';

    FOR v_order IN
        SELECT order_id FROM orders WHERE event_id = p_event_id AND status = 'paid' ORDER BY order_id
    LOOP
        PERFORM refund_order(v_order, 'Event cancelled: ' || p_reason);
        v_refunded := v_refunded + 1;
    END LOOP;

    RETURN v_refunded;
END $$;

-- -----------------------------------------------------------------------------
-- expire_stale_orders: background sweeper (e.g. pg_cron every minute).
-- SKIP LOCKED lets several sweepers run without blocking each other or users.
-- -----------------------------------------------------------------------------
CREATE FUNCTION expire_stale_orders(p_batch int DEFAULT 1000)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_count int;
BEGIN
    WITH stale AS (
        SELECT order_id FROM orders
         WHERE status = 'pending' AND expires_at <= now()
         ORDER BY expires_at
         LIMIT p_batch
           FOR UPDATE SKIP LOCKED
    ), expired AS (
        UPDATE orders o SET status = 'expired'
          FROM stale s WHERE o.order_id = s.order_id
     RETURNING o.order_id
    ), released AS (
        UPDATE tickets t SET status = 'released'
          FROM expired e WHERE t.order_id = e.order_id AND t.status = 'reserved'
     RETURNING 1
    )
    SELECT count(*) INTO v_count FROM expired;
    RETURN v_count;
END $$;

-- -----------------------------------------------------------------------------
-- check_in_ticket: scan a ticket at the gate. Each ticket admits exactly once.
-- -----------------------------------------------------------------------------
CREATE FUNCTION check_in_ticket(p_ticket_code uuid)
RETURNS TABLE (ticket_id bigint, event_title text, section text, row_label text, seat_number smallint)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
DECLARE
    v_ticket tickets%ROWTYPE;
BEGIN
    UPDATE tickets t SET checked_in_at = now()
     WHERE t.ticket_code = p_ticket_code AND t.status = 'issued' AND t.checked_in_at IS NULL
    RETURNING t.* INTO v_ticket;

    IF NOT FOUND THEN
        SELECT * INTO v_ticket FROM tickets t WHERE t.ticket_code = p_ticket_code;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown ticket' USING ERRCODE = 'TK404';
        ELSIF v_ticket.checked_in_at IS NOT NULL THEN
            RAISE EXCEPTION 'Ticket already used at %', v_ticket.checked_in_at USING ERRCODE = 'TK031';
        ELSE
            RAISE EXCEPTION 'Ticket is not valid (status: %)', v_ticket.status USING ERRCODE = 'TK030';
        END IF;
    END IF;

    RETURN QUERY
    SELECT v_ticket.ticket_id, e.title, sc.name, s.row_label, s.seat_number
      FROM seats s
      JOIN sections sc USING (section_id)
      JOIN events e ON e.event_id = v_ticket.event_id
     WHERE s.seat_id = v_ticket.seat_id;
END $$;

-- -----------------------------------------------------------------------------
-- available_seats: the seat map a buyer sees. Lapsed holds count as available.
-- -----------------------------------------------------------------------------
CREATE FUNCTION available_seats(p_event_id bigint)
RETURNS TABLE (seat_id bigint, section text, row_label text, seat_number smallint,
               is_accessible boolean, price_cents integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ticketing, public AS $$
    SELECT s.seat_id, sc.name, s.row_label, s.seat_number, s.is_accessible, pt.price_cents
      FROM events e
      JOIN price_tiers pt ON pt.event_id = e.event_id
      JOIN sections sc    ON sc.section_id = pt.section_id
      JOIN seats s        ON s.section_id = pt.section_id
     WHERE e.event_id = p_event_id
       AND NOT EXISTS (
            SELECT 1
              FROM tickets t JOIN orders o USING (order_id, event_id)
             WHERE t.event_id = e.event_id AND t.seat_id = s.seat_id
               AND t.status IN ('reserved', 'issued')
               AND NOT (o.status = 'pending' AND o.expires_at <= now()))
     ORDER BY sc.name, s.row_label, s.seat_number;
$$;

-- -----------------------------------------------------------------------------
-- complete_past_events: housekeeping; marks finished on-sale events completed.
-- -----------------------------------------------------------------------------
CREATE FUNCTION complete_past_events()
RETURNS int
LANGUAGE sql SECURITY DEFINER SET search_path = ticketing, public AS $$
    WITH done AS (
        UPDATE events SET status = 'completed'
         WHERE status = 'on_sale' AND ends_at < now()
     RETURNING 1
    )
    SELECT count(*)::int FROM done;
$$;
