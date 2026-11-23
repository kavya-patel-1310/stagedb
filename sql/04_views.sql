-- =============================================================================
-- StageDB · 04_views.sql
-- Reporting layer. Analysts query these views, never the base tables.
-- =============================================================================

SET search_path = ticketing, public;

-- -----------------------------------------------------------------------------
-- Live sales dashboard per event.
-- -----------------------------------------------------------------------------
CREATE VIEW v_event_sales AS
WITH capacity AS (
    SELECT pt.event_id, count(*) AS sellable_seats
      FROM price_tiers pt JOIN seats s ON s.section_id = pt.section_id
     GROUP BY pt.event_id
), sales AS (
    SELECT event_id,
           count(*) FILTER (WHERE status = 'issued')                AS tickets_sold,
           count(*) FILTER (WHERE status = 'reserved')              AS tickets_on_hold,
           count(*) FILTER (WHERE status = 'refunded')              AS tickets_refunded,
           count(*) FILTER (WHERE checked_in_at IS NOT NULL)        AS tickets_checked_in,
           COALESCE(sum(price_cents) FILTER (WHERE status = 'issued'), 0) AS revenue_cents
      FROM tickets
     GROUP BY event_id
)
SELECT e.event_id,
       e.title,
       e.category,
       e.status,
       v.name                                   AS venue,
       v.city,
       e.starts_at,
       COALESCE(c.sellable_seats, 0)            AS sellable_seats,
       COALESCE(s.tickets_sold, 0)              AS tickets_sold,
       COALESCE(s.tickets_on_hold, 0)           AS tickets_on_hold,
       COALESCE(s.tickets_refunded, 0)          AS tickets_refunded,
       COALESCE(s.tickets_checked_in, 0)        AS tickets_checked_in,
       COALESCE(s.revenue_cents, 0)             AS revenue_cents,
       round(100.0 * COALESCE(s.tickets_sold, 0) / NULLIF(c.sellable_seats, 0), 1) AS sell_through_pct,
       round(100.0 * COALESCE(s.tickets_checked_in, 0) / NULLIF(s.tickets_sold, 0), 1) AS attendance_pct
  FROM events e
  JOIN venues v USING (venue_id)
  LEFT JOIN capacity c USING (event_id)
  LEFT JOIN sales s    USING (event_id);

COMMENT ON VIEW v_event_sales IS 'Per-event capacity, sales, holds, refunds, revenue, sell-through and attendance.';

-- -----------------------------------------------------------------------------
-- Customer lifetime value with RFM-style segmentation.
-- -----------------------------------------------------------------------------
CREATE VIEW v_customer_ltv AS
WITH spend AS (
    SELECT o.customer_id,
           count(*) FILTER (WHERE o.status IN ('paid', 'refunded'))           AS orders_placed,
           count(*) FILTER (WHERE o.status = 'refunded')                      AS orders_refunded,
           COALESCE(sum(o.total_cents) FILTER (WHERE o.status = 'paid'), 0)    AS net_spend_cents,
           count(DISTINCT o.event_id) FILTER (WHERE o.status = 'paid')         AS events_attended,
           min(o.paid_at)                                                      AS first_purchase_at,
           max(o.paid_at)                                                      AS last_purchase_at
      FROM orders o
     GROUP BY o.customer_id
)
SELECT c.customer_id,
       c.full_name,
       c.email,
       COALESCE(s.orders_placed, 0)    AS orders_placed,
       COALESCE(s.orders_refunded, 0)  AS orders_refunded,
       COALESCE(s.events_attended, 0)  AS events_attended,
       COALESCE(s.net_spend_cents, 0)  AS net_spend_cents,
       s.first_purchase_at,
       s.last_purchase_at,
       CASE
           WHEN s.last_purchase_at IS NULL                              THEN 'prospect'
           WHEN ntile(10) OVER w = 1 AND s.last_purchase_at > now() - interval '180 days' THEN 'vip'
           WHEN s.last_purchase_at > now() - interval '180 days'        THEN 'active'
           WHEN s.last_purchase_at > now() - interval '365 days'        THEN 'at_risk'
           ELSE 'lapsed'
       END AS segment
  FROM customers c
  LEFT JOIN spend s USING (customer_id)
WINDOW w AS (ORDER BY COALESCE(s.net_spend_cents, 0) DESC);

COMMENT ON VIEW v_customer_ltv IS 'Net spend per customer; VIP = top decile by spend and purchased in last 180 days.';

-- -----------------------------------------------------------------------------
-- Daily revenue rollup: materialized because it scans the full ledger.
-- Unique index enables REFRESH ... CONCURRENTLY (readers never blocked).
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_daily_revenue AS
WITH gross AS (
    SELECT date_trunc('day', p.created_at)::date AS day, e.category,
           count(*) AS orders, sum(p.amount_cents) AS gross_cents
      FROM payments p
      JOIN orders o USING (order_id)
      JOIN events e USING (event_id)
     WHERE p.status = 'succeeded'
     GROUP BY 1, 2
), refunded AS (
    SELECT date_trunc('day', r.created_at)::date AS day, e.category,
           sum(r.amount_cents) AS refund_cents
      FROM refunds r
      JOIN payments p USING (payment_id)
      JOIN orders o   USING (order_id)
      JOIN events e   USING (event_id)
     GROUP BY 1, 2
)
SELECT COALESCE(g.day, r.day)           AS day,
       COALESCE(g.category, r.category) AS category,
       COALESCE(g.orders, 0)            AS orders,
       COALESCE(g.gross_cents, 0)       AS gross_cents,
       COALESCE(r.refund_cents, 0)      AS refund_cents,
       COALESCE(g.gross_cents, 0) - COALESCE(r.refund_cents, 0) AS net_cents
  FROM gross g
  FULL JOIN refunded r ON r.day = g.day AND r.category = g.category
WITH NO DATA;

CREATE UNIQUE INDEX uq_mv_daily_revenue ON mv_daily_revenue (day, category);

CREATE FUNCTION refresh_reporting()
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ticketing, public AS $$
BEGIN
    IF (SELECT relispopulated FROM pg_class WHERE oid = 'ticketing.mv_daily_revenue'::regclass) THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_revenue;
    ELSE
        REFRESH MATERIALIZED VIEW mv_daily_revenue;
    END IF;
END $$;
