-- =============================================================================
-- StageDB · seed/seed.sql
-- Generates a realistic, reproducible dataset (fixed random seed) entirely with
-- set-based SQL: ~100k customers, 8 venues / ~15k seats, 300 events spanning
-- ~18 months of history plus upcoming events, and a few hundred thousand
-- tickets with payments, refunds, abandoned carts and gate check-ins.
--
-- Dates are generated relative to now(), so "upcoming" events are always in the
-- future no matter when the seed is run.
-- =============================================================================

\set ON_ERROR_STOP on
SET search_path = ticketing, public;
SET client_min_messages = warning;
SELECT setseed(0.42) \gset

BEGIN;

-- Bulk-loading history: skip per-row audit records (re-enabled at the end).
-- FKs, CHECKs and unique indexes all remain fully enforced during the load.
ALTER TABLE events   DISABLE TRIGGER audit;
ALTER TABLE orders   DISABLE TRIGGER audit;
ALTER TABLE payments DISABLE TRIGGER audit;
ALTER TABLE refunds  DISABLE TRIGGER audit;

-- -----------------------------------------------------------------------------
-- Organizers & venues
-- -----------------------------------------------------------------------------
INSERT INTO organizers (name, contact_email)
SELECT n, lower(regexp_replace(n, '[^A-Za-z]+', '', 'g')) || '@example.com'
FROM unnest(ARRAY[
    'Bluewave Live', 'Northstar Promotions', 'Crescent Sports Group', 'Open Curtain Productions',
    'Laugh Track Comedy', 'Summit Conferences', 'Vinyl & Velvet', 'Arena Nation',
    'Brightlight Theatricals', 'TechForward Events', 'Golden Hour Presents', 'Metro Athletics'
]) AS n;

INSERT INTO venues (name, city, country_code, timezone) VALUES
    ('Harborview Arena',       'Seattle',  'US', 'America/Los_Angeles'),
    ('Lakeshore Amphitheater', 'Chicago',  'US', 'America/Chicago'),
    ('The Copper Hall',        'Austin',   'US', 'America/Chicago'),
    ('Riverside Stadium',      'London',   'GB', 'Europe/London'),
    ('Grand Meridian Theatre', 'New York', 'US', 'America/New_York'),
    ('Maple Leaf Pavilion',    'Toronto',  'CA', 'America/Toronto'),
    ('Indigo Dome',            'Mumbai',   'IN', 'Asia/Kolkata'),
    ('Southern Cross Centre',  'Sydney',   'AU', 'Australia/Sydney');

-- 4–7 sections per venue
INSERT INTO sections (venue_id, name)
SELECT v.venue_id, sn.name
FROM venues v
CROSS JOIN LATERAL unnest(ARRAY['Floor', 'Lower Bowl A', 'Lower Bowl B', 'Upper Bowl A',
                                'Upper Bowl B', 'Balcony', 'VIP Box'])
           WITH ORDINALITY AS sn(name, ord)
WHERE sn.ord <= 4 + (v.venue_id % 4);

-- Rectangular seat grids; first row of every section is wheelchair accessible
INSERT INTO seats (section_id, venue_id, row_label, seat_number, is_accessible)
SELECT sc.section_id, sc.venue_id, chr(64 + r), n::smallint, (r = 1 AND n <= 4)
FROM (SELECT section_id, venue_id,
             CASE WHEN name = 'VIP Box' THEN 3 ELSE 8 + floor(random() * 14)::int END AS n_rows,
             CASE WHEN name = 'VIP Box' THEN 10 ELSE 14 + floor(random() * 18)::int END AS per_row
        FROM sections) sc
CROSS JOIN LATERAL generate_series(1, sc.n_rows)  AS r
CROSS JOIN LATERAL generate_series(1, sc.per_row) AS n;

-- -----------------------------------------------------------------------------
-- Customers (100,000)
-- -----------------------------------------------------------------------------
INSERT INTO customers (email, full_name, phone, created_at)
SELECT lower(f || '.' || l || i || '@' || (ARRAY['gmail.com','outlook.com','yahoo.com','proton.me','icloud.com'])[1 + i % 5]),
       f || ' ' || l,
       CASE WHEN random() < 0.8 THEN '+1 555 ' || lpad((floor(random() * 10000000))::text, 7, '0') END,
       now() - interval '900 days' * random()
FROM generate_series(1, 100000) AS i
CROSS JOIN LATERAL (SELECT
    (ARRAY['Aarav','Olivia','Liam','Emma','Noah','Ava','Mateo','Sophia','Ethan','Isabella',
           'Lucas','Mia','Arjun','Amelia','Kenji','Harper','Diego','Evelyn','Omar','Chloe',
           'Wei','Zara','Leo','Priya','Hugo','Nora','Elijah','Aisha','James','Sofia',
           'Rohan','Grace','Mason','Layla','Kai','Ines','Ben','Maya','Sam','Lena'])[1 + floor(random() * 40)::int] AS f,
    (ARRAY['Smith','Patel','Garcia','Kim','Johnson','Nguyen','Brown','Singh','Martinez','Chen',
           'Williams','Khan','Lopez','Tanaka','Davis','Silva','Miller','Okafor','Wilson','Haddad',
           'Moore','Rossi','Taylor','Ivanova','Anderson','Mehta','Thomas','Dubois','Jackson','Cohen',
           'White','Sato','Harris','Novak','Martin','Reyes','Clark','Fischer','Lewis','Larsen'])[1 + floor(random() * 40)::int] AS l
    , i AS dummy) AS names;

-- -----------------------------------------------------------------------------
-- Events (300): one every ~19 days per venue, ~540 days back to ~165 days ahead
-- -----------------------------------------------------------------------------
INSERT INTO events (organizer_id, venue_id, title, category, starts_at, ends_at, status, max_tickets_per_customer)
SELECT 1 + floor(random() * 12)::int,
       ev.venue_id,
       CASE ev.category
           WHEN 'concert'    THEN (ARRAY['Neon Harbor','The Midnight Owls','Saffron Skies','Glass Arcade','Luna Vega','Echo Parade'])[1 + floor(random()*6)::int]
                                  || ': ' || (ARRAY['Afterglow Tour','Live in Concert','World Tour','Unplugged','Greatest Hits Night'])[1 + floor(random()*5)::int]
           WHEN 'sports'     THEN (ARRAY['Harbor Hawks','Lake City Lions','Metro Monarchs','Coastal Comets'])[1 + floor(random()*4)::int]
                                  || ' vs ' || (ARRAY['Desert Foxes','Iron Bears','River Kings','Summit Wolves'])[1 + floor(random()*4)::int]
           WHEN 'theatre'    THEN (ARRAY['The Lighthouse Keeper','A Winter''s Tale','Paper Cities','The Last Tram','Moonlight Requiem'])[1 + floor(random()*5)::int]
           WHEN 'comedy'     THEN (ARRAY['Stand-Up Saturday','Late Night Laughs','The Roast Hour','Improv Unleashed'])[1 + floor(random()*4)::int]
           ELSE                   (ARRAY['DataCon','CloudSummit','DevWorld','AI Frontiers','SecureOps Forum'])[1 + floor(random()*5)::int]
                                  || ' ' || extract(year FROM ev.starts_at)::int
       END,
       ev.category,
       ev.starts_at,
       ev.starts_at + ev.duration,
       CASE
           WHEN ev.starts_at + ev.duration < now() THEN CASE WHEN random() < 0.04 THEN 'cancelled' ELSE 'completed' END
           ELSE CASE WHEN ev.r < 0.05 THEN 'cancelled' WHEN ev.r < 0.15 THEN 'draft' ELSE 'on_sale' END
       END::event_status,
       CASE WHEN random() < 0.2 THEN 4 ELSE 8 END
FROM (
    SELECT 1 + (i - 1) % 8 AS venue_id,
           date_trunc('day', now()) - interval '540 days'
               + make_interval(days => ((i - 1) / 8) * 19 + floor(random() * 10)::int)
               + make_interval(hours => 18 + floor(random() * 3)::int) AS starts_at,
           make_interval(mins => 120 + 30 * floor(random() * 5)::int) AS duration,
           (ARRAY['concert','concert','sports','sports','theatre','comedy','conference'])[1 + floor(random() * 7)::int]::event_category AS category,
           random() AS r
    FROM generate_series(1, 300) AS i
) ev;

-- -----------------------------------------------------------------------------
-- Price tiers: category base price x section multiplier x +-15% noise ($5 steps)
-- -----------------------------------------------------------------------------
INSERT INTO price_tiers (event_id, section_id, venue_id, price_cents)
SELECT e.event_id, s.section_id, s.venue_id,
       (round(
           CASE e.category WHEN 'concert' THEN 6500 WHEN 'sports' THEN 5500 WHEN 'theatre' THEN 8000
                           WHEN 'comedy' THEN 4000 ELSE 25000 END
         * CASE WHEN s.name IN ('Floor', 'VIP Box') THEN 2.5
                WHEN s.name LIKE 'Lower%' THEN 1.5
                WHEN s.name = 'Balcony' THEN 0.8 ELSE 1.0 END
         * (0.85 + random() * 0.30) / 500) * 500)::int
FROM events e
JOIN sections s ON s.venue_id = e.venue_id;

-- -----------------------------------------------------------------------------
-- Orders. Seats are sold in contiguous blocks of 1-4 within a row (groups of
-- friends sit together). Each event gets its own fill rate.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE seed_blocks ON COMMIT DROP AS
WITH ev AS (
    SELECT e.event_id, e.venue_id, e.status, e.starts_at,
           -- final fill rate, scaled down for upcoming events by how much of the
           -- 120-day sales window has elapsed (late-booking curve)
           CASE e.status
               WHEN 'completed' THEN 0.55 + random() * 0.40
               WHEN 'cancelled' THEN 0.30 + random() * 0.30
               ELSE (0.55 + random() * 0.40) * power(GREATEST(0.03, LEAST(1.0,
                        extract(epoch FROM now() - (e.starts_at - interval '120 days')) / (120 * 86400))), 1.3)
           END AS fill
      FROM events e
     WHERE e.status <> 'draft'
), blocks AS (
    SELECT ev.event_id, ev.status, ev.starts_at, ev.fill,
           s.section_id, s.row_label,
           (s.seat_number - 1) / (1 + (ev.event_id + s.section_id) % 4) AS blk,
           -- premium sections sell faster than the cheap seats
           CASE WHEN sc.name IN ('VIP Box', 'Floor') THEN 1.10
                WHEN sc.name LIKE 'Lower%' THEN 1.0
                WHEN sc.name LIKE 'Upper%' THEN 0.88 ELSE 0.78 END AS demand
      FROM ev
      JOIN seats s     ON s.venue_id = ev.venue_id
      JOIN sections sc ON sc.section_id = s.section_id
     GROUP BY 1, 2, 3, 4, 5, 6, 7, 8
)
SELECT row_number() OVER (ORDER BY event_id, section_id, row_label, blk) AS order_id,
       event_id, status AS event_status, starts_at, section_id, row_label, blk
  FROM blocks
 WHERE random() < LEAST(0.99, fill * demand);

CREATE TEMP TABLE seed_orders ON COMMIT DROP AS
WITH base AS (
    SELECT b.order_id, b.event_id, b.event_status, b.starts_at,
           b.section_id, b.row_label, b.blk,
           -- power-law customer choice -> realistic repeat buyers / VIPs
           1 + floor(100000 * power(random(), 1.7))::bigint AS customer_id,
           -- sales open 120 days out (never in the future); purchases cluster
           -- close to the event and are never later than now()
           so.opens_at
             + (LEAST(now() - interval '1 minute', b.starts_at - interval '1 hour') - so.opens_at)
               * sqrt(random()) AS created_at,
           random() AS r
      FROM seed_blocks b
     CROSS JOIN LATERAL (SELECT LEAST(b.starts_at - interval '120 days', now() - interval '30 days') AS opens_at) so
)
SELECT order_id, event_id, section_id, row_label, blk, customer_id,
       CASE
           WHEN event_status = 'cancelled' THEN 'refunded'
           WHEN event_status = 'on_sale' AND r < 0.015 THEN 'pending'
           WHEN r < 0.045 THEN 'refunded'
           ELSE 'paid'
       END::order_status AS status,
       CASE WHEN event_status = 'on_sale' AND r < 0.015
            THEN now() - interval '20 minutes' * random()
            ELSE created_at END AS created_at,
       starts_at
  FROM base;

-- Abandoned checkouts: an earlier hold on the same seats that lapsed unpaid.
INSERT INTO seed_orders
SELECT (SELECT max(order_id) FROM seed_blocks) + row_number() OVER (ORDER BY order_id),
       event_id, section_id, row_label, blk,
       1 + floor(100000 * random())::bigint,
       'expired'::order_status,
       created_at - interval '1 day' * random() - interval '15 minutes',
       starts_at
  FROM seed_orders
 WHERE status <> 'pending' AND random() < 0.06;

INSERT INTO orders (order_id, customer_id, event_id, status, total_cents, expires_at, paid_at, created_at, updated_at)
OVERRIDING SYSTEM VALUE
SELECT o.order_id, o.customer_id, o.event_id, o.status, 0,
       CASE WHEN o.status IN ('pending', 'expired') THEN o.created_at + interval '10 minutes' END,
       CASE WHEN o.status IN ('paid', 'refunded') THEN LEAST(now(), o.created_at + interval '9 minutes' * random() + interval '20 seconds') END,
       o.created_at, o.created_at
  FROM seed_orders o
 ORDER BY o.order_id;

DO $$ BEGIN PERFORM setval(pg_get_serial_sequence('ticketing.orders', 'order_id'), (SELECT max(order_id) FROM ticketing.orders)); END $$;

-- Tickets for every seat in each order's block
INSERT INTO tickets (order_id, event_id, venue_id, seat_id, price_cents, status, checked_in_at, created_at)
SELECT o.order_id, o.event_id, s.venue_id, s.seat_id, pt.price_cents,
       CASE o.status WHEN 'paid' THEN 'issued' WHEN 'refunded' THEN 'refunded'
                     WHEN 'pending' THEN 'reserved' ELSE 'released' END::ticket_status,
       CASE WHEN o.status = 'paid' AND e.status = 'completed' AND random() < 0.92
            THEN e.starts_at - interval '75 minutes' * random() END,
       o.created_at
  FROM seed_orders o
  JOIN events e       ON e.event_id = o.event_id
  JOIN seats s        ON s.section_id = o.section_id AND s.row_label = o.row_label
                     AND (s.seat_number - 1) / (1 + (o.event_id + o.section_id) % 4) = o.blk
  JOIN price_tiers pt ON pt.event_id = o.event_id AND pt.section_id = s.section_id
 ORDER BY o.order_id, s.seat_id;

UPDATE orders o SET total_cents = t.total
  FROM (SELECT order_id, sum(price_cents) AS total FROM tickets GROUP BY order_id) t
 WHERE t.order_id = o.order_id;

-- -----------------------------------------------------------------------------
-- Payments (plus ~2% failed first attempts) and refunds
-- -----------------------------------------------------------------------------
INSERT INTO payments (order_id, amount_cents, provider, provider_ref, status, created_at)
SELECT order_id, total_cents,
       (ARRAY['stripe','stripe','stripe','paypal','adyen'])[1 + floor(random() * 5)::int],
       'pi_fail_' || md5(order_id::text || ':fail'), 'failed', paid_at - interval '1 minute'
  FROM orders WHERE status IN ('paid', 'refunded') AND random() < 0.02;

INSERT INTO payments (order_id, amount_cents, provider, provider_ref, status, created_at)
SELECT order_id, total_cents,
       (ARRAY['stripe','stripe','stripe','paypal','adyen'])[1 + floor(random() * 5)::int],
       'pi_' || md5(order_id::text || ':ok'), 'succeeded', paid_at
  FROM orders WHERE status IN ('paid', 'refunded')
 ORDER BY order_id;

INSERT INTO refunds (payment_id, amount_cents, reason, created_at)
SELECT p.payment_id, p.amount_cents,
       CASE WHEN e.status = 'cancelled' THEN 'Event cancelled: organizer decision'
            ELSE (ARRAY['Customer request','Cannot attend','Duplicate purchase','Schedule conflict'])[1 + floor(random() * 4)::int] END,
       LEAST(now(), GREATEST(p.created_at + interval '1 hour',
             p.created_at + (e.starts_at - interval '1 day' - p.created_at) * random()))
  FROM payments p
  JOIN orders o USING (order_id)
  JOIN events e USING (event_id)
 WHERE o.status = 'refunded' AND p.status = 'succeeded'
 ORDER BY p.payment_id;

-- A customer's account must predate their first order
ALTER TABLE customers DISABLE TRIGGER set_updated_at;
UPDATE customers c SET created_at = f.first_order - interval '2 days' * random() - interval '1 hour',
                       updated_at = f.first_order - interval '1 hour'
  FROM (SELECT customer_id, min(created_at) AS first_order FROM orders GROUP BY customer_id) f
 WHERE f.customer_id = c.customer_id AND c.created_at > f.first_order - interval '1 hour';
UPDATE customers SET updated_at = created_at WHERE updated_at < created_at;
ALTER TABLE customers ENABLE TRIGGER set_updated_at;

ALTER TABLE events   ENABLE TRIGGER audit;
ALTER TABLE orders   ENABLE TRIGGER audit;
ALTER TABLE payments ENABLE TRIGGER audit;
ALTER TABLE refunds  ENABLE TRIGGER audit;

COMMIT;

ANALYZE;
DO $$ BEGIN PERFORM ticketing.refresh_reporting(); END $$;

\echo
\echo '== StageDB seed complete =='
SELECT * FROM (
SELECT 'customers' AS table_name, count(*) AS rows FROM customers
UNION ALL SELECT 'venues',      count(*) FROM venues
UNION ALL SELECT 'sections',    count(*) FROM sections
UNION ALL SELECT 'seats',       count(*) FROM seats
UNION ALL SELECT 'events',      count(*) FROM events
UNION ALL SELECT 'price_tiers', count(*) FROM price_tiers
UNION ALL SELECT 'orders',      count(*) FROM orders
UNION ALL SELECT 'tickets',     count(*) FROM tickets
UNION ALL SELECT 'payments',    count(*) FROM payments
UNION ALL SELECT 'refunds',     count(*) FROM refunds
) t ORDER BY rows DESC;
