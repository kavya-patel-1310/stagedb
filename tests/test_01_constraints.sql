-- Declarative integrity: CHECK, UNIQUE, composite FKs, EXCLUDE.
SET search_path = ticketing, public;

DO $$ BEGIN
    PERFORM test.raises($q$INSERT INTO ticketing.customers (email, full_name) VALUES ('not-an-email', 'X')$q$,
        '23514', 'malformed email is rejected');

    PERFORM test.raises($q$INSERT INTO ticketing.customers (email, full_name) VALUES ('ALICE@Test.Example', 'Dup')$q$,
        '23505', 'email uniqueness is case-insensitive (citext)');

    PERFORM test.raises($q$INSERT INTO ticketing.venues (name, city, country_code, timezone)
                           VALUES ('Bad TZ', 'Nowhere', 'US', 'Mars/Olympus_Mons')$q$,
        '23514', 'unknown IANA timezone is rejected');

    PERFORM test.raises($q$INSERT INTO ticketing.events (organizer_id, venue_id, title, category, starts_at, ends_at)
                           VALUES (1, 1, 'Backwards', 'concert', now() + interval '5 days', now() + interval '4 days')$q$,
        '23514', 'event cannot end before it starts');

    PERFORM test.raises($q$INSERT INTO ticketing.events (organizer_id, venue_id, title, category, starts_at, ends_at)
                           VALUES (1, 1, 'Clash', 'concert', now() + interval '30 days 1 hour', now() + interval '30 days 5 hours')$q$,
        '23P01', 'EXCLUDE constraint blocks overlapping events at the same venue');
END $$;

DO $$ BEGIN
    INSERT INTO events (organizer_id, venue_id, title, category, starts_at, ends_at, status)
    VALUES (1, 1, 'Cancelled Clash', 'concert', now() + interval '30 days 1 hour', now() + interval '30 days 5 hours', 'cancelled');
    PERFORM test.ok(true, 'a cancelled event does not occupy the venue slot');

    INSERT INTO events (organizer_id, venue_id, title, category, starts_at, ends_at, status)
    VALUES (1, 2, 'Same Time Other Venue', 'concert', now() + interval '60 days 1 hour', now() + interval '60 days 2 hours', 'draft');
    PERFORM test.ok(true, 'the Draft Show time slot is free at a different venue');

    PERFORM test.raises($q$INSERT INTO ticketing.price_tiers (event_id, section_id, venue_id, price_cents) VALUES (1, 3, 2, 100)$q$,
        '23503', 'price tier cannot reference a section in another venue');

    PERFORM test.raises($q$INSERT INTO ticketing.price_tiers (event_id, section_id, venue_id, price_cents) VALUES (1, 2, 1, -5)$q$,
        '23514', 'negative prices are rejected');
END $$;

DO $$
DECLARE v_order bigint;
BEGIN
    INSERT INTO orders (customer_id, event_id, expires_at) VALUES (1, 1, now() + interval '10 min')
    RETURNING order_id INTO v_order;

    EXECUTE format($q$INSERT INTO ticketing.tickets (order_id, event_id, venue_id, seat_id, price_cents)
                      VALUES (%s, 1, 1, 1, 5000)$q$, v_order);
    PERFORM test.ok(true, 'ticket insert for a valid seat succeeds');

    PERFORM test.raises(format($q$INSERT INTO ticketing.tickets (order_id, event_id, venue_id, seat_id, price_cents)
                                  VALUES (%s, 1, 1, 1, 5000)$q$, v_order),
        '23505', 'partial unique index prevents selling the same seat twice');

    PERFORM test.raises(format($q$INSERT INTO ticketing.tickets (order_id, event_id, venue_id, seat_id, price_cents)
                                  VALUES (%s, 1, 1, 16, 5000)$q$, v_order),
        '23503', 'composite FK prevents a ticket for a seat in a different venue');

    PERFORM test.raises(format($q$INSERT INTO ticketing.tickets (order_id, event_id, venue_id, seat_id, price_cents)
                                  VALUES (%s, 4, 2, 16, 5000)$q$, v_order),
        '23503', 'composite FK prevents a ticket whose event differs from its order''s event');

    UPDATE tickets SET status = 'released' WHERE order_id = v_order;
    EXECUTE format($q$INSERT INTO ticketing.tickets (order_id, event_id, venue_id, seat_id, price_cents)
                      VALUES (%s, 1, 1, 1, 5000)$q$, v_order);
    PERFORM test.ok(true, 'a released seat can be sold again');

    PERFORM test.raises(format($q$UPDATE ticketing.tickets SET checked_in_at = now() WHERE order_id = %s AND status = 'reserved'$q$, v_order),
        '23514', 'only issued tickets can carry a check-in time');

    PERFORM test.raises($q$INSERT INTO ticketing.orders (customer_id, event_id) VALUES (1, 1)$q$,
        '23514', 'pending orders must have a hold expiry');
END $$;
