-- Minimal assertion library (no external dependencies such as pgTAP).
-- Each passing assertion emits "PASS: <message>"; a failure raises and stops the file.

CREATE SCHEMA IF NOT EXISTS test;

CREATE OR REPLACE FUNCTION test.ok(p_condition boolean, p_msg text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_condition IS NOT TRUE THEN
        RAISE EXCEPTION 'FAIL: %', p_msg;
    END IF;
    RAISE NOTICE 'PASS: %', p_msg;
END $$;

CREATE OR REPLACE FUNCTION test.eq(p_actual anyelement, p_expected anyelement, p_msg text)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    IF p_actual IS DISTINCT FROM p_expected THEN
        RAISE EXCEPTION 'FAIL: % (expected %, got %)', p_msg, p_expected, p_actual;
    END IF;
    RAISE NOTICE 'PASS: %', p_msg;
END $$;

-- Runs p_sql inside a subtransaction and asserts it fails with SQLSTATE p_state.
-- The failed statement's effects are rolled back; the surrounding test continues.
CREATE OR REPLACE FUNCTION test.raises(p_sql text, p_state text, p_msg text)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_state text;
    v_text  text;
BEGIN
    BEGIN
        EXECUTE p_sql;
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_text = MESSAGE_TEXT;
        IF v_state = p_state THEN
            RAISE NOTICE 'PASS: % [%]', p_msg, v_state;
            RETURN;
        END IF;
        RAISE EXCEPTION 'FAIL: % (expected SQLSTATE %, got %: %)', p_msg, p_state, v_state, v_text;
    END;
    RAISE EXCEPTION 'FAIL: % (expected SQLSTATE %, but statement succeeded)', p_msg, p_state;
END $$;

-- Tests switch to restricted roles mid-file; they still need the helpers.
GRANT USAGE ON SCHEMA test TO PUBLIC;
