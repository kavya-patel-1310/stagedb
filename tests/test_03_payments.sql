-- confirm_payment(): capture, idempotency, validation, ledger immutability
SET search_path = ticketing, public;

DO $$
DECLARE
    v_order   bigint;
    v_pay     bigint;
    v_pay2    bigint;
    v_order2  bigint;
BEGIN
    v_order := reserve_seats(1, 1, ARRAY[1, 2]::bigint[]);

    PERFORM test.raises(format('SELECT ticketing.confirm_payment(%s, 9999, ''stripe'', ''pi_wrong'')', v_order), 'TK012',
        'payment amount must match the order total');

    v_pay := confirm_payment(v_order, 10000, 'stripe', 'pi_test_001');
    PERFORM test.eq((SELECT status FROM orders WHERE order_id = v_order), 'paid'::order_status, 'order becomes paid');
    PERFORM test.ok((SELECT paid_at IS NOT NULL AND expires_at IS NULL FROM orders WHERE order_id = v_order),
        'paid_at set and hold cleared');
    PERFORM test.eq((SELECT count(*) FROM tickets WHERE order_id = v_order AND status = 'issued'), 2::bigint,
        'tickets become issued');

    v_pay2 := confirm_payment(v_order, 10000, 'stripe', 'pi_test_001');
    PERFORM test.eq(v_pay2, v_pay, 'replaying the same provider reference is idempotent');
    PERFORM test.eq((SELECT count(*) FROM payments WHERE order_id = v_order), 1::bigint, 'replay creates no duplicate payment');

    PERFORM test.raises(format('SELECT ticketing.confirm_payment(%s, 10000, ''stripe'', ''pi_test_002'')', v_order), 'TK010',
        'a paid order cannot be paid twice');

    v_order2 := reserve_seats(2, 1, ARRAY[5]::bigint[]);
    PERFORM test.raises(format('SELECT ticketing.confirm_payment(%s, 5000, ''stripe'', ''pi_test_001'')', v_order2), 'TK000',
        'a provider reference cannot be reused for a different order');

    UPDATE orders SET expires_at = now() - interval '1 second' WHERE order_id = v_order2;
    PERFORM test.raises(format('SELECT ticketing.confirm_payment(%s, 5000, ''stripe'', ''pi_test_003'')', v_order2), 'TK011',
        'an order whose hold expired cannot be paid');

    PERFORM test.raises(format('UPDATE ticketing.payments SET amount_cents = 1 WHERE payment_id = %s', v_pay), 'TK101',
        'payments ledger is append-only (no UPDATE)');
    PERFORM test.raises(format('DELETE FROM ticketing.payments WHERE payment_id = %s', v_pay), 'TK101',
        'payments ledger is append-only (no DELETE)');
    PERFORM test.raises(format($q$INSERT INTO ticketing.payments (order_id, amount_cents, provider, provider_ref, status)
                                  VALUES (%s, 10000, 'stripe', 'pi_dup_success', 'succeeded')$q$, v_order), '23505',
        'at most one successful payment per order');

    INSERT INTO payments (order_id, amount_cents, provider, provider_ref, status)
    VALUES (v_order, 10000, 'paypal', 'pp_failed_attempt', 'failed');
    PERFORM test.ok(true, 'failed payment attempts are recorded without limit');
END $$;
