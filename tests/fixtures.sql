-- Small, hand-built fixture with predictable IDs (loaded into a fresh database).
--
--   venue 1 "Test Arena":  section 1 'A' seats 1-10 (priced)   section 2 'B' seats 11-15 (NOT priced for event 1)
--   venue 2 "Other Hall":  section 3 'Main' seats 16-20
--   customers 1 alice, 2 bob, 3 carol
--   events 1 on_sale (+30d, max 4/customer) · 2 draft · 3 on_sale but already started · 4 at venue 2

SET search_path = ticketing, public;

INSERT INTO organizers (name, contact_email) VALUES ('Test Promotions', 'ops@test.example');

INSERT INTO venues (name, city, country_code, timezone) VALUES
    ('Test Arena', 'Seattle', 'US', 'America/Los_Angeles'),
    ('Other Hall', 'Austin',  'US', 'America/Chicago');

INSERT INTO sections (venue_id, name) VALUES (1, 'A'), (1, 'B'), (2, 'Main');

INSERT INTO seats (section_id, venue_id, row_label, seat_number)
SELECT 1, 1, 'A', g FROM generate_series(1, 10) g;
INSERT INTO seats (section_id, venue_id, row_label, seat_number)
SELECT 2, 1, 'A', g FROM generate_series(1, 5) g;
INSERT INTO seats (section_id, venue_id, row_label, seat_number)
SELECT 3, 2, 'A', g FROM generate_series(1, 5) g;

INSERT INTO customers (email, full_name) VALUES
    ('alice@test.example', 'Alice Tester'),
    ('bob@test.example',   'Bob Tester'),
    ('carol@test.example', 'Carol Tester');

INSERT INTO events (organizer_id, venue_id, title, category, starts_at, ends_at, status, max_tickets_per_customer) VALUES
    (1, 1, 'Future Show',      'concert', now() + interval '30 days', now() + interval '30 days 3 hours', 'on_sale', 4),
    (1, 1, 'Draft Show',       'theatre', now() + interval '60 days', now() + interval '60 days 3 hours', 'draft',   8),
    (1, 1, 'Started Show',     'comedy',  now() - interval '1 hour',  now() + interval '1 hour',          'on_sale', 8),
    (1, 2, 'Other Venue Show', 'sports',  now() + interval '30 days', now() + interval '30 days 3 hours', 'on_sale', 8);

INSERT INTO price_tiers (event_id, section_id, venue_id, price_cents) VALUES
    (1, 1, 1, 5000), (2, 1, 1, 5000), (3, 1, 1, 5000), (4, 3, 2, 3000);
