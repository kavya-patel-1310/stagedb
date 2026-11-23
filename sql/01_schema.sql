-- =============================================================================
-- StageDB · 01_schema.sql
-- Core relational model (3NF), with integrity enforced declaratively wherever
-- possible: CHECK, composite FOREIGN KEYs, partial UNIQUE indexes and an
-- EXCLUDE constraint. Procedural logic (triggers) is used only where a
-- declarative rule cannot express the invariant.
-- =============================================================================

SET search_path = ticketing, public;

-- -----------------------------------------------------------------------------
-- Enumerated types
-- -----------------------------------------------------------------------------
CREATE TYPE event_status   AS ENUM ('draft', 'on_sale', 'cancelled', 'completed');
CREATE TYPE event_category AS ENUM ('concert', 'sports', 'theatre', 'comedy', 'conference');
CREATE TYPE order_status   AS ENUM ('pending', 'paid', 'expired', 'cancelled', 'refunded');
CREATE TYPE ticket_status  AS ENUM ('reserved', 'issued', 'released', 'refunded');
CREATE TYPE payment_status AS ENUM ('succeeded', 'failed');

-- -----------------------------------------------------------------------------
-- People
-- -----------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email        citext      NOT NULL UNIQUE
                 CHECK (email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    full_name    text        NOT NULL CHECK (length(btrim(full_name)) BETWEEN 1 AND 120),
    phone        text        CHECK (phone ~ '^\+?[0-9 ()-]{7,20}$'),
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE customers IS 'Ticket buyers. Email is unique case-insensitively (citext).';

CREATE TABLE organizers (
    organizer_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name          text   NOT NULL UNIQUE,
    contact_email citext NOT NULL CHECK (contact_email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Physical inventory: venue -> section -> seat
-- venue_id is carried down to seats so that composite foreign keys can prove,
-- without triggers, that a ticket's seat is physically inside the event's venue.
-- -----------------------------------------------------------------------------
CREATE TABLE venues (
    venue_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name         text    NOT NULL,
    city         text    NOT NULL,
    country_code char(2) NOT NULL CHECK (country_code ~ '^[A-Z]{2}$'),
    timezone     text    NOT NULL,           -- IANA name, validated by trigger
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (name, city)
);

CREATE TABLE sections (
    section_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    venue_id     bigint NOT NULL REFERENCES venues ON DELETE CASCADE,
    name         text   NOT NULL,
    UNIQUE (venue_id, name),
    UNIQUE (section_id, venue_id)            -- target for composite FKs
);

CREATE TABLE seats (
    seat_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    section_id    bigint   NOT NULL,
    venue_id      bigint   NOT NULL,
    row_label     text     NOT NULL CHECK (row_label ~ '^[A-Z]{1,2}$'),
    seat_number   smallint NOT NULL CHECK (seat_number > 0),
    is_accessible boolean  NOT NULL DEFAULT false,
    UNIQUE (section_id, row_label, seat_number),
    UNIQUE (seat_id, venue_id),              -- target for composite FKs
    FOREIGN KEY (section_id, venue_id) REFERENCES sections (section_id, venue_id) ON DELETE CASCADE
);

-- -----------------------------------------------------------------------------
-- Events & pricing
-- -----------------------------------------------------------------------------
CREATE TABLE events (
    event_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    organizer_id  bigint         NOT NULL REFERENCES organizers,
    venue_id      bigint         NOT NULL REFERENCES venues,
    title         text           NOT NULL CHECK (length(btrim(title)) > 0),
    category      event_category NOT NULL,
    starts_at     timestamptz    NOT NULL,
    ends_at       timestamptz    NOT NULL,
    status        event_status   NOT NULL DEFAULT 'draft',
    max_tickets_per_customer smallint NOT NULL DEFAULT 8
                  CHECK (max_tickets_per_customer BETWEEN 1 AND 20),
    created_at    timestamptz    NOT NULL DEFAULT now(),
    updated_at    timestamptz    NOT NULL DEFAULT now(),
    CHECK (ends_at > starts_at),
    CHECK (ends_at - starts_at <= interval '24 hours'),
    UNIQUE (event_id, venue_id),             -- target for composite FKs
    -- A venue can never host two (non-cancelled) events whose time ranges overlap.
    CONSTRAINT no_overlapping_events_per_venue
        EXCLUDE USING gist (venue_id WITH =, tstzrange(starts_at, ends_at, '[)') WITH &&)
        WHERE (status <> 'cancelled')
);

CREATE TABLE price_tiers (
    event_id     bigint  NOT NULL,
    section_id   bigint  NOT NULL,
    venue_id     bigint  NOT NULL,
    price_cents  integer NOT NULL CHECK (price_cents BETWEEN 0 AND 10000000),
    PRIMARY KEY (event_id, section_id),
    -- section must belong to the event's venue: enforced by two composite FKs
    FOREIGN KEY (event_id, venue_id)   REFERENCES events   (event_id, venue_id) ON DELETE CASCADE,
    FOREIGN KEY (section_id, venue_id) REFERENCES sections (section_id, venue_id)
);
COMMENT ON TABLE price_tiers IS 'Price per (event, section). Seats in unpriced sections are not for sale.';

-- -----------------------------------------------------------------------------
-- Commerce: orders -> tickets, payments -> refunds
-- -----------------------------------------------------------------------------
CREATE TABLE orders (
    order_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id  bigint       NOT NULL REFERENCES customers,
    event_id     bigint       NOT NULL REFERENCES events,
    status       order_status NOT NULL DEFAULT 'pending',
    total_cents  bigint       NOT NULL DEFAULT 0 CHECK (total_cents >= 0),
    currency     char(3)      NOT NULL DEFAULT 'USD' CHECK (currency ~ '^[A-Z]{3}$'),
    expires_at   timestamptz,
    paid_at      timestamptz,
    created_at   timestamptz  NOT NULL DEFAULT now(),
    updated_at   timestamptz  NOT NULL DEFAULT now(),
    UNIQUE (order_id, event_id),             -- target for composite FK from tickets
    CHECK (status <> 'pending' OR expires_at IS NOT NULL),
    CHECK (status NOT IN ('paid', 'refunded') OR paid_at IS NOT NULL)
);
COMMENT ON COLUMN orders.expires_at IS 'Seat hold deadline for pending orders; stale holds are released lazily and by expire_stale_orders().';

CREATE TABLE tickets (
    ticket_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      bigint        NOT NULL,
    event_id      bigint        NOT NULL,
    venue_id      bigint        NOT NULL,
    seat_id       bigint        NOT NULL,
    price_cents   integer       NOT NULL CHECK (price_cents >= 0),
    status        ticket_status NOT NULL DEFAULT 'reserved',
    ticket_code   uuid          NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    checked_in_at timestamptz,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    FOREIGN KEY (order_id, event_id) REFERENCES orders (order_id, event_id) ON DELETE CASCADE,
    FOREIGN KEY (event_id, venue_id) REFERENCES events (event_id, venue_id),
    FOREIGN KEY (seat_id,  venue_id) REFERENCES seats  (seat_id,  venue_id),
    CHECK (checked_in_at IS NULL OR status = 'issued')
);

-- THE core business invariant: a seat can be held or sold at most once per event.
-- Released/refunded tickets drop out of the index, so the seat becomes sellable again.
CREATE UNIQUE INDEX uq_tickets_active_seat
    ON tickets (event_id, seat_id)
    WHERE status IN ('reserved', 'issued');

CREATE TABLE payments (
    payment_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      bigint         NOT NULL REFERENCES orders,
    amount_cents  bigint         NOT NULL CHECK (amount_cents > 0),
    provider      text           NOT NULL CHECK (provider IN ('stripe', 'paypal', 'adyen')),
    provider_ref  text           NOT NULL UNIQUE,   -- idempotency key from the PSP
    status        payment_status NOT NULL,
    created_at    timestamptz    NOT NULL DEFAULT now()
);
-- At most one successful payment per order (failed attempts are unlimited).
CREATE UNIQUE INDEX uq_payments_one_success_per_order
    ON payments (order_id) WHERE status = 'succeeded';

CREATE TABLE refunds (
    refund_id     bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    payment_id    bigint      NOT NULL REFERENCES payments,
    amount_cents  bigint      NOT NULL CHECK (amount_cents > 0),
    reason        text        NOT NULL CHECK (length(btrim(reason)) > 0),
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- -----------------------------------------------------------------------------
-- Audit log: range-partitioned by month so old data can be detached/dropped
-- cheaply and recent-history queries prune to a single partition.
-- -----------------------------------------------------------------------------
CREATE TABLE audit_log (
    audit_id    bigint GENERATED ALWAYS AS IDENTITY,
    table_name  text        NOT NULL,
    operation   char(1)     NOT NULL CHECK (operation IN ('I', 'U', 'D')),
    row_pk      bigint      NOT NULL,
    old_row     jsonb,
    new_row     jsonb,
    changed_by  text        NOT NULL,
    changed_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (audit_id, changed_at)
) PARTITION BY RANGE (changed_at);

CREATE TABLE audit_log_default PARTITION OF audit_log DEFAULT;

-- Creates monthly partitions [start_month, start_month + n months). Idempotent.
CREATE FUNCTION ensure_audit_partitions(p_start date, p_months int)
RETURNS int LANGUAGE plpgsql AS $$
DECLARE
    m       date := date_trunc('month', p_start)::date;
    created int  := 0;
    part    text;
BEGIN
    FOR i IN 0 .. p_months - 1 LOOP
        part := format('audit_log_%s', to_char(m + make_interval(months => i), 'YYYY_MM'));
        IF to_regclass('ticketing.' || part) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE ticketing.%I PARTITION OF ticketing.audit_log FOR VALUES FROM (%L) TO (%L)',
                part, m + make_interval(months => i), m + make_interval(months => i + 1));
            created := created + 1;
        END IF;
    END LOOP;
    RETURN created;
END $$;

DO $$ BEGIN PERFORM ticketing.ensure_audit_partitions((now() - interval '1 month')::date, 15); END $$;
