-- reserve_seats() and available_seats()
SET search_path = ticketing, public;

DO $$
DECLARE
    v_order bigint;
    v_avail int;
BEGIN
    SELECT count(*) INTO v_avail FROM available_seats(1);
    PERFORM test.eq(v_avail, 10, 'event 1 starts with 10 sellable seats (unpriced section excluded)');

    v_order := reserve_seats(1, 1, ARRAY[1, 2, 3]::bigint[]);
    PERFORM test.ok(v_order IS NOT NULL, 'reserve_seats returns an order id');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_order), 'pending'::order_status, 'new order is pending');
    PERFORM test.eq((SELECT total_cents FROM orders WHERE order_id = v_order), 15000::bigint, 'order total = sum of seat prices');
    PERFORM test.eq((SELECT count(*) FROM tickets WHERE order_id = v_order AND status = 'reserved'), 3::bigint, 'three tickets reserved');
    PERFORM test.ok((SELECT expires_at BETWEEN now() + interval '9 min' AND now() + interval '11 min'
                       FROM orders WHERE order_id = v_order), 'default hold is 10 minutes');

    SELECT count(*) INTO v_avail FROM available_seats(1);
    PERFORM test.eq(v_avail, 7, 'held seats disappear from the seat map');

    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[3,4]::bigint[])', 'TK409',
        'another customer cannot take an already-held seat');
    PERFORM test.eq((SELECT count(*) FROM orders WHERE customer_id = 2), 0::bigint,
        'failed reservation leaves no partial order behind (atomicity)');

    PERFORM test.raises('SELECT ticketing.reserve_seats(1, 1, ARRAY[4,5]::bigint[])', 'TK004',
        'per-customer limit (4) counts seats already held');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 2, ARRAY[1]::bigint[])', 'TK002',
        'draft events are not on sale');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 3, ARRAY[1]::bigint[])', 'TK003',
        'events that already started cannot be booked');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[11]::bigint[])', 'TK005',
        'seats in an unpriced section are not sellable');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[16]::bigint[])', 'TK005',
        'seats from another venue are not sellable');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[]::bigint[])', 'TK000',
        'empty seat list is rejected');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[5,5]::bigint[])', 'TK000',
        'duplicate seats in one request are rejected');
    PERFORM test.raises($q$SELECT ticketing.reserve_seats(2, 1, ARRAY[5]::bigint[], interval '3 hours')$q$, 'TK000',
        'holds longer than 1 hour are rejected');
    PERFORM test.raises('SELECT ticketing.reserve_seats(999, 1, ARRAY[5]::bigint[])', 'TK404',
        'unknown customer is rejected');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 999, ARRAY[5]::bigint[])', 'TK404',
        'unknown event is rejected');

    v_order := reserve_seats(2, 4, ARRAY[16, 17]::bigint[]);
    PERFORM test.eq((SELECT total_cents FROM orders WHERE order_id = v_order), 6000::bigint,
        'booking at a second venue uses that event''s price tier');
END $$;
