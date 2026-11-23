-- Seat holds expire: lazily on re-booking, and in bulk via the sweeper.
SET search_path = ticketing, public;

DO $$
DECLARE
    v_stale  bigint;
    v_fresh  bigint;
    v_new    bigint;
    v_swept  int;
BEGIN
    v_stale := reserve_seats(1, 1, ARRAY[1, 2]::bigint[]);
    v_fresh := reserve_seats(2, 1, ARRAY[3]::bigint[]);
    UPDATE orders SET expires_at = now() - interval '1 minute' WHERE order_id = v_stale;

    PERFORM test.ok(EXISTS (SELECT 1 FROM available_seats(1) WHERE seat_id = 1),
        'seat map already shows seats from a lapsed hold as available');

    v_new := reserve_seats(3, 1, ARRAY[2]::bigint[]);
    PERFORM test.ok(v_new IS NOT NULL, 'a lapsed seat can be re-booked before the sweeper runs');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_stale), 'expired'::order_status,
        'the lapsed order was expired lazily by reserve_seats');
    PERFORM test.eq((SELECT count(*) FROM tickets WHERE order_id = v_stale AND status = 'released'), 2::bigint,
        'all seats of the lapsed order were released (not only the re-booked one)');

    UPDATE orders SET expires_at = now() - interval '1 minute' WHERE order_id = v_new;
    v_swept := expire_stale_orders();
    PERFORM test.eq(v_swept, 1, 'sweeper expires exactly the lapsed orders');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_fresh), 'pending'::order_status,
        'sweeper leaves orders with a live hold alone');
    PERFORM test.eq(expire_stale_orders(), 0, 'sweeper is idempotent');
END $$;
