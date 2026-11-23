-- =============================================================================
-- StageDB · 05_indexes.sql
-- Every index here backs a specific access path. Foreign keys that are already
-- the leading column of a UNIQUE constraint are not indexed twice.
-- =============================================================================

SET search_path = ticketing, public;

-- FK support (enables fast joins and prevents seq-scans on parent DELETE)
CREATE INDEX ix_events_organizer      ON events   (organizer_id);
CREATE INDEX ix_seats_venue           ON seats    (venue_id);
CREATE INDEX ix_price_tiers_section   ON price_tiers (section_id);
CREATE INDEX ix_tickets_order         ON tickets  (order_id);
CREATE INDEX ix_tickets_seat          ON tickets  (seat_id);
CREATE INDEX ix_payments_order        ON payments (order_id);
CREATE INDEX ix_refunds_payment       ON refunds  (payment_id);

-- "My orders" page: newest first, index-only friendly
CREATE INDEX ix_orders_customer_recent ON orders (customer_id, created_at DESC) INCLUDE (status, total_cents);
CREATE INDEX ix_orders_event_status    ON orders (event_id, status);

-- Sweeper: only pending orders are ever scanned -> tiny partial index
CREATE INDEX ix_orders_pending_expiry  ON orders (expires_at) WHERE status = 'pending';

-- Event discovery: upcoming on-sale events, and fuzzy title search
CREATE INDEX ix_events_upcoming        ON events (starts_at) WHERE status = 'on_sale';
CREATE INDEX ix_events_title_trgm      ON events USING gin (title gin_trgm_ops);

-- Sales aggregation by event and status
CREATE INDEX ix_tickets_event_status   ON tickets (event_id, status) INCLUDE (price_cents);

-- Audit lookups ("history of order 123"); created on the parent, cascades to partitions
CREATE INDEX ix_audit_row              ON audit_log (table_name, row_pk, changed_at DESC);
