-- State machines and gate check-in
SET search_path = ticketing, public;

DO $$
DECLARE
    v_order bigint;
    v_code  uuid;
    r       record;
BEGIN
    -- Event lifecycle
    PERFORM test.raises('UPDATE ticketing.events SET status = ''completed'' WHERE event_id = 2', 'TK100',
        'draft -> completed is illegal');
    UPDATE events SET status = 'on_sale' WHERE event_id = 2;
    PERFORM test.ok(true, 'draft -> on_sale is legal');
    PERFORM test.raises('UPDATE ticketing.events SET status = ''draft'' WHERE event_id = 2', 'TK100',
        'on_sale -> draft is illegal');

    -- Order & ticket lifecycle
    v_order := reserve_seats(1, 1, ARRAY[1]::bigint[]);
    PERFORM test.raises(format('UPDATE ticketing.orders SET status = ''refunded'' WHERE order_id = %s', v_order), 'TK100',
        'pending -> refunded is illegal (must be paid first)');
    PERFORM confirm_payment(v_order, 5000, 'stripe', 'pi_lc1');
    PERFORM test.raises(format('UPDATE ticketing.orders SET status = ''pending'' WHERE order_id = %s', v_order), 'TK100',
        'paid -> pending is illegal');
    PERFORM test.raises(format('UPDATE ticketing.tickets SET status = ''reserved'' WHERE order_id = %s', v_order), 'TK100',
        'issued -> reserved is illegal');

    -- Check-in
    SELECT ticket_code INTO v_code FROM tickets WHERE order_id = v_order;
    SELECT * INTO r FROM check_in_ticket(v_code);
    PERFORM test.eq(r.event_title, 'Future Show', 'check-in returns the event');
    PERFORM test.eq(r.section || '-' || r.row_label || r.seat_number, 'A-A1', 'check-in returns the seat location');
    PERFORM test.raises(format('SELECT * FROM ticketing.check_in_ticket(%L)', v_code), 'TK031',
        'a ticket admits only once');
    PERFORM test.raises(format('SELECT * FROM ticketing.check_in_ticket(%L)', gen_random_uuid()), 'TK404',
        'unknown ticket codes are rejected');

    v_order := reserve_seats(2, 1, ARRAY[2]::bigint[]);
    PERFORM test.raises(format('SELECT * FROM ticketing.check_in_ticket(%L)',
                               (SELECT ticket_code FROM tickets WHERE order_id = v_order)), 'TK030',
        'an unpaid (reserved) ticket cannot be used');
END $$;
