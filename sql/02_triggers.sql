-- =============================================================================
-- StageDB · 02_triggers.sql
-- Rules that cannot be expressed declaratively:
--   * lifecycle state machines for events, orders and tickets
--   * refund totals may never exceed the captured payment
--   * IANA timezone validation
--   * updated_at maintenance and a generic row-level audit trail
-- =============================================================================

SET search_path = ticketing, public;

-- -----------------------------------------------------------------------------
-- updated_at
-- -----------------------------------------------------------------------------
CREATE FUNCTION trg_set_updated_at() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END $$;

CREATE TRIGGER set_updated_at BEFORE UPDATE ON customers FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON events    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();
CREATE TRIGGER set_updated_at BEFORE UPDATE ON orders    FOR EACH ROW EXECUTE FUNCTION trg_set_updated_at();

-- -----------------------------------------------------------------------------
-- Timezone validation (CHECK constraints must be immutable, so use a trigger)
-- -----------------------------------------------------------------------------
CREATE FUNCTION trg_validate_venue_timezone() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
        RAISE EXCEPTION 'Unknown IANA timezone "%"', NEW.timezone
              USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER validate_timezone BEFORE INSERT OR UPDATE OF timezone ON venues
    FOR EACH ROW EXECUTE FUNCTION trg_validate_venue_timezone();

-- -----------------------------------------------------------------------------
-- State machines. Each table lists its legal transitions; anything else fails.
--
--   events : draft -> on_sale | cancelled ; on_sale -> cancelled | completed
--   orders : pending -> paid | expired | cancelled ; paid -> refunded
--   tickets: reserved -> issued | released ; issued -> refunded
-- -----------------------------------------------------------------------------
CREATE FUNCTION trg_enforce_status_transition() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    allowed text[];
BEGIN
    IF NEW.status = OLD.status THEN
        RETURN NEW;
    END IF;

    allowed := CASE TG_TABLE_NAME
        WHEN 'events' THEN CASE OLD.status::text
            WHEN 'draft'    THEN ARRAY['on_sale', 'cancelled']
            WHEN 'on_sale'  THEN ARRAY['cancelled', 'completed'] END
        WHEN 'orders' THEN CASE OLD.status::text
            WHEN 'pending'  THEN ARRAY['paid', 'expired', 'cancelled']
            WHEN 'paid'     THEN ARRAY['refunded'] END
        WHEN 'tickets' THEN CASE OLD.status::text
            WHEN 'reserved' THEN ARRAY['issued', 'released']
            WHEN 'issued'   THEN ARRAY['refunded'] END
    END;

    IF allowed IS NULL OR NOT (NEW.status::text = ANY (allowed)) THEN
        RAISE EXCEPTION 'Illegal % status transition: % -> %', TG_TABLE_NAME, OLD.status, NEW.status
              USING ERRCODE = 'TK100';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER enforce_status_transition BEFORE UPDATE OF status ON events
    FOR EACH ROW EXECUTE FUNCTION trg_enforce_status_transition();
CREATE TRIGGER enforce_status_transition BEFORE UPDATE OF status ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_enforce_status_transition();
CREATE TRIGGER enforce_status_transition BEFORE UPDATE OF status ON tickets
    FOR EACH ROW EXECUTE FUNCTION trg_enforce_status_transition();

-- -----------------------------------------------------------------------------
-- Refund guard: SUM(refunds) <= payment amount, and only for successful payments.
-- Locks the parent payment row so two concurrent refunds are serialized.
-- -----------------------------------------------------------------------------
CREATE FUNCTION trg_refund_within_payment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_amount   bigint;
    v_status   payment_status;
    v_refunded bigint;
BEGIN
    SELECT amount_cents, status INTO v_amount, v_status
    FROM payments WHERE payment_id = NEW.payment_id
    FOR UPDATE;

    IF v_status <> 'succeeded' THEN
        RAISE EXCEPTION 'Cannot refund a % payment', v_status USING ERRCODE = 'TK021';
    END IF;

    SELECT COALESCE(sum(amount_cents), 0) INTO v_refunded
    FROM refunds WHERE payment_id = NEW.payment_id;

    IF v_refunded + NEW.amount_cents > v_amount THEN
        RAISE EXCEPTION 'Refund total % would exceed payment amount %',
              v_refunded + NEW.amount_cents, v_amount
              USING ERRCODE = 'TK022';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER refund_within_payment BEFORE INSERT ON refunds
    FOR EACH ROW EXECUTE FUNCTION trg_refund_within_payment();

-- Refunds and payments are an append-only financial ledger.
CREATE FUNCTION trg_ledger_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; % is not allowed', TG_TABLE_NAME, TG_OP
          USING ERRCODE = 'TK101';
END $$;

CREATE TRIGGER ledger_append_only BEFORE UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_append_only();
CREATE TRIGGER ledger_append_only BEFORE UPDATE OR DELETE ON refunds
    FOR EACH ROW EXECUTE FUNCTION trg_ledger_append_only();

-- -----------------------------------------------------------------------------
-- Generic audit trail. TG_ARGV[0] = name of the primary-key column.
-- For UPDATEs only the columns that actually changed are stored.
-- The acting user comes from the app (SET app.actor = '...') or the session.
-- -----------------------------------------------------------------------------
CREATE FUNCTION trg_audit() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_old jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
    v_new jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
    v_pk  bigint := COALESCE(v_new, v_old) ->> TG_ARGV[0];
BEGIN
    IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(n.key, n.value), jsonb_object_agg(n.key, v_old -> n.key)
          INTO v_new, v_old
          FROM jsonb_each(v_new) n
         WHERE n.value IS DISTINCT FROM v_old -> n.key
           AND n.key <> 'updated_at';
        IF v_new IS NULL THEN
            RETURN NULL;                -- no-op update, nothing to record
        END IF;
    END IF;

    INSERT INTO audit_log (table_name, operation, row_pk, old_row, new_row, changed_by)
    VALUES (TG_TABLE_NAME, left(TG_OP, 1), v_pk, v_old, v_new,
            COALESCE(NULLIF(current_setting('app.actor', true), ''), session_user));
    RETURN NULL;
END $$;

CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION trg_audit('event_id');
CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON orders
    FOR EACH ROW EXECUTE FUNCTION trg_audit('order_id');
CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON payments
    FOR EACH ROW EXECUTE FUNCTION trg_audit('payment_id');
CREATE TRIGGER audit AFTER INSERT OR UPDATE OR DELETE ON refunds
    FOR EACH ROW EXECUTE FUNCTION trg_audit('refund_id');
