-- Audit trail, role privileges and Row-Level Security
SET search_path = ticketing, public;

DO $$
DECLARE
    v_order bigint;
    v_log   audit_log%ROWTYPE;
BEGIN
    PERFORM set_config('app.actor', 'checkout-service', true);
    v_order := reserve_seats(1, 1, ARRAY[1]::bigint[]);
    PERFORM confirm_payment(v_order, 5000, 'stripe', 'pi_audit');

    PERFORM test.eq((SELECT count(*) FROM audit_log WHERE table_name = 'orders' AND row_pk = v_order AND operation = 'I'),
        1::bigint, 'order creation is audited');

    SELECT * INTO v_log FROM audit_log
     WHERE table_name = 'orders' AND row_pk = v_order AND new_row ->> 'status' = 'paid';
    PERFORM test.ok(FOUND, 'status change to paid is audited');
    PERFORM test.eq(v_log.old_row ->> 'status', 'pending', 'audit keeps the previous value');
    PERFORM test.ok(NOT (v_log.new_row ? 'customer_id'), 'UPDATE audit stores only the changed columns');
    PERFORM test.eq(v_log.changed_by, 'checkout-service', 'acting service is recorded via app.actor');
    PERFORM test.eq((SELECT count(*) FROM audit_log WHERE table_name = 'payments'), 1::bigint, 'payment insert is audited');
END $$;

-- Customer role: RLS restricts rows to the identified customer
DO $$
DECLARE v_o1 bigint; v_o2 bigint;
BEGIN
    v_o1 := reserve_seats(1, 1, ARRAY[2]::bigint[]);
    v_o2 := reserve_seats(2, 1, ARRAY[3]::bigint[]);

    SET LOCAL ROLE stagedb_customer;
    PERFORM test.eq((SELECT count(*) FROM ticketing.orders), 0::bigint,
        'RLS: a customer session that has not identified itself sees no orders');

    PERFORM set_config('app.customer_id', '2', true);
    PERFORM test.eq((SELECT array_agg(DISTINCT customer_id) FROM ticketing.orders), ARRAY[2::bigint],
        'RLS: customer 2 sees only their own orders');
    PERFORM test.eq((SELECT count(*) FROM ticketing.tickets), 1::bigint,
        'RLS: customer 2 sees only their own tickets');
    PERFORM test.raises('SELECT * FROM ticketing.customers', '42501',
        'customer role cannot read the customers table (PII)');
    PERFORM test.raises('SELECT ticketing.reserve_seats(2, 1, ARRAY[4]::bigint[])', '42501',
        'customer role cannot call booking functions directly');
    RESET ROLE;
END $$;

-- App role: can call the API, cannot bypass it
DO $$
DECLARE v_o bigint;
BEGIN
    SET LOCAL ROLE stagedb_app;
    v_o := ticketing.reserve_seats(3, 1, ARRAY[4]::bigint[]);
    PERFORM test.ok(v_o IS NOT NULL, 'app role books through the SECURITY DEFINER API');
    PERFORM test.raises($q$INSERT INTO ticketing.orders (customer_id, event_id, expires_at) VALUES (1, 1, now())$q$, '42501',
        'app role cannot write to tables directly');
    PERFORM test.raises($q$UPDATE ticketing.tickets SET status = 'issued'$q$, '42501',
        'app role cannot issue tickets without payment');
    PERFORM test.ok((SELECT count(*) FROM ticketing.orders) > 0, 'app role can read all orders');
    RESET ROLE;

    SET LOCAL ROLE stagedb_analyst;
    PERFORM test.ok((SELECT count(*) FROM ticketing.v_event_sales) = 4, 'analyst can read reporting views');
    PERFORM test.raises('SELECT * FROM ticketing.orders', '42501', 'analyst cannot read raw orders');
    RESET ROLE;
END $$;
