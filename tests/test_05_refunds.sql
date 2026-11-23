-- refund_order(), cancel_event() and the refund ledger guard
SET search_path = ticketing, public;

DO $$
DECLARE
    v_order  bigint;
    v_order2 bigint;
    v_hold   bigint;
    v_pay    bigint;
    v_count  int;
BEGIN
    v_order := reserve_seats(1, 1, ARRAY[1, 2]::bigint[]);
    PERFORM test.raises(format('SELECT ticketing.refund_order(%s, ''x'')', v_order), 'TK020',
        'unpaid orders cannot be refunded');

    v_pay := confirm_payment(v_order, 10000, 'stripe', 'pi_r1');
    PERFORM refund_order(v_order, 'Cannot attend');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_order), 'refunded'::order_status, 'order is refunded');
    PERFORM test.eq((SELECT sum(amount_cents) FROM refunds WHERE payment_id = v_pay), 10000::numeric, 'full amount refunded');
    PERFORM test.ok(EXISTS (SELECT 1 FROM available_seats(1) WHERE seat_id = 1), 'refunded seats return to inventory');

    PERFORM test.raises(format('SELECT ticketing.refund_order(%s, ''again'')', v_order), 'TK020',
        'an order cannot be refunded twice');
    PERFORM test.raises(format($q$INSERT INTO ticketing.refunds (payment_id, amount_cents, reason) VALUES (%s, 1, 'extra')$q$, v_pay),
        'TK022', 'trigger blocks refunds exceeding the captured amount');

    -- Checked-in tickets are not refundable
    v_order2 := reserve_seats(2, 1, ARRAY[5]::bigint[]);
    PERFORM confirm_payment(v_order2, 5000, 'stripe', 'pi_r2');
    PERFORM check_in_ticket((SELECT ticket_code FROM tickets WHERE order_id = v_order2));
    PERFORM test.raises(format('SELECT ticketing.refund_order(%s, ''x'')', v_order2), 'TK020',
        'orders with checked-in tickets cannot be refunded');
END $$;

DO $$
DECLARE
    v_paid1 bigint;
    v_paid2 bigint;
    v_hold  bigint;
    v_n     int;
BEGIN
    v_paid1 := reserve_seats(1, 4, ARRAY[16]::bigint[]);
    PERFORM confirm_payment(v_paid1, 3000, 'stripe', 'pi_c1');
    v_paid2 := reserve_seats(2, 4, ARRAY[17, 18]::bigint[]);
    PERFORM confirm_payment(v_paid2, 6000, 'adyen', 'pi_c2');
    v_hold  := reserve_seats(3, 4, ARRAY[19]::bigint[]);

    v_n := cancel_event(4, 'Weather');
    PERFORM test.eq(v_n, 2, 'cancel_event refunds every paid order');
    PERFORM test.eq((SELECT status FROM events WHERE event_id = 4), 'cancelled'::event_status, 'event is cancelled');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_hold), 'cancelled'::order_status, 'pending holds are voided');
    PERFORM test.eq((SELECT count(*) FROM tickets WHERE event_id = 4 AND status IN ('reserved', 'issued')), 0::bigint,
        'no active tickets remain for the cancelled event');
    PERFORM test.eq((SELECT sum(r.amount_cents) FROM refunds r JOIN payments p USING (payment_id) JOIN orders o USING (order_id)
                      WHERE o.event_id = 4), 9000::numeric, 'refund total equals everything captured');
    PERFORM test.raises('SELECT ticketing.reserve_seats(1, 4, ARRAY[20]::bigint[])', 'TK002',
        'a cancelled event can no longer be booked');
END $$;
