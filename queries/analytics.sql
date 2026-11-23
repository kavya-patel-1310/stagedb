-- =============================================================================
-- StageDB · queries/analytics.sql
-- Business questions answered with SQL. Run against the seeded database:
--     psql -d stagedb -f queries/analytics.sql
-- Techniques: CTEs, window functions (RANK, LAG, NTILE, running totals),
-- FILTER aggregates, GROUPING SETS/ROLLUP, percentiles, cohort analysis.
-- =============================================================================

SET search_path = ticketing, public;
\pset footer off

-- -----------------------------------------------------------------------------
\echo '\n[Q1] Monthly net revenue with month-over-month growth and running total'
-- -----------------------------------------------------------------------------
WITH monthly AS (
    SELECT date_trunc('month', day)::date AS month, sum(net_cents) / 100.0 AS net_revenue
      FROM mv_daily_revenue
     GROUP BY 1
)
SELECT to_char(month, 'YYYY-MM')                                        AS month,
       to_char(net_revenue, 'FM$999,999,990')                           AS net_revenue,
       round(100 * (net_revenue / NULLIF(lag(net_revenue) OVER w, 0) - 1), 1) AS mom_growth_pct,
       to_char(sum(net_revenue) OVER w, 'FM$999,999,990')               AS running_total
  FROM monthly
WINDOW w AS (ORDER BY month)
 ORDER BY month DESC
 LIMIT 12;

-- -----------------------------------------------------------------------------
\echo '\n[Q2] Top 3 events by revenue in each category (completed events)'
-- -----------------------------------------------------------------------------
SELECT category, rnk, title, venue, to_char(revenue_cents / 100.0, 'FM$9,999,990') AS revenue, sell_through_pct
  FROM (SELECT *, rank() OVER (PARTITION BY category ORDER BY revenue_cents DESC) AS rnk
          FROM v_event_sales WHERE status = 'completed') ranked
 WHERE rnk <= 3
 ORDER BY category, rnk;

-- -----------------------------------------------------------------------------
\echo '\n[Q3] Venue utilisation: average sell-through and no-show rate, with a grand total (ROLLUP)'
-- -----------------------------------------------------------------------------
SELECT COALESCE(venue, '== ALL VENUES ==')                      AS venue,
       count(*)                                                 AS events,
       round(avg(sell_through_pct), 1)                          AS avg_sell_through_pct,
       round(100 - 100.0 * sum(tickets_checked_in) / NULLIF(sum(tickets_sold), 0), 1) AS no_show_pct,
       to_char(sum(revenue_cents) / 100.0, 'FM$999,999,990')    AS revenue
  FROM v_event_sales
 WHERE status = 'completed'
 GROUP BY ROLLUP (venue)
 ORDER BY venue IS NULL, avg(sell_through_pct) DESC;

-- -----------------------------------------------------------------------------
\echo '\n[Q4] Booking lead time: how far ahead do people buy? (percentiles by category)'
-- -----------------------------------------------------------------------------
SELECT e.category,
       count(*)                                                                       AS paid_orders,
       round(percentile_cont(0.25) WITHIN GROUP (ORDER BY extract(epoch FROM e.starts_at - o.paid_at) / 86400)::numeric, 1) AS p25_days,
       round(percentile_cont(0.50) WITHIN GROUP (ORDER BY extract(epoch FROM e.starts_at - o.paid_at) / 86400)::numeric, 1) AS median_days,
       round(percentile_cont(0.90) WITHIN GROUP (ORDER BY extract(epoch FROM e.starts_at - o.paid_at) / 86400)::numeric, 1) AS p90_days
  FROM orders o JOIN events e USING (event_id)
 WHERE o.status = 'paid'
 GROUP BY e.category
 ORDER BY median_days DESC;

-- -----------------------------------------------------------------------------
\echo '\n[Q5] Checkout funnel: holds placed vs. converted vs. abandoned, by month'
-- -----------------------------------------------------------------------------
SELECT to_char(date_trunc('month', created_at), 'YYYY-MM')               AS month,
       count(*)                                                          AS holds_placed,
       count(*) FILTER (WHERE status IN ('paid', 'refunded'))            AS converted,
       count(*) FILTER (WHERE status = 'expired')                        AS abandoned,
       round(100.0 * count(*) FILTER (WHERE status IN ('paid', 'refunded')) / count(*), 1) AS conversion_pct
  FROM orders
 WHERE created_at >= date_trunc('month', now()) - interval '6 months'
 GROUP BY 1
 ORDER BY 1;

-- -----------------------------------------------------------------------------
\echo '\n[Q6] Customer cohorts: % of each first-purchase quarter who bought again later'
-- -----------------------------------------------------------------------------
WITH firsts AS (
    SELECT customer_id, min(paid_at) AS first_paid
      FROM orders WHERE status IN ('paid', 'refunded')
     GROUP BY customer_id
)
SELECT to_char(date_trunc('quarter', f.first_paid), 'YYYY-"Q"Q')         AS cohort,
       count(*)                                                          AS customers,
       count(*) FILTER (WHERE EXISTS (
            SELECT 1 FROM orders o
             WHERE o.customer_id = f.customer_id AND o.status IN ('paid', 'refunded')
               AND o.paid_at > f.first_paid + interval '1 day'))          AS returned,
       round(100.0 * count(*) FILTER (WHERE EXISTS (
            SELECT 1 FROM orders o
             WHERE o.customer_id = f.customer_id AND o.status IN ('paid', 'refunded')
               AND o.paid_at > f.first_paid + interval '1 day')) / count(*), 1) AS repeat_rate_pct
  FROM firsts f
 GROUP BY 1
 ORDER BY 1;

-- -----------------------------------------------------------------------------
\echo '\n[Q7] Customer segments: size and share of lifetime revenue'
-- -----------------------------------------------------------------------------
SELECT segment,
       count(*)                                                                  AS customers,
       to_char(sum(net_spend_cents) / 100.0, 'FM$999,999,990')                   AS revenue,
       round(100.0 * sum(net_spend_cents) / sum(sum(net_spend_cents)) OVER (), 1) AS revenue_share_pct,
       to_char(avg(net_spend_cents) / 100.0, 'FM$9,990.00')                      AS avg_spend
  FROM v_customer_ltv
 GROUP BY segment
 ORDER BY sum(net_spend_cents) DESC;

-- -----------------------------------------------------------------------------
\echo '\n[Q8] Price elasticity proxy: sell-through by price band (NTILE quartiles within category)'
-- -----------------------------------------------------------------------------
WITH tier_sales AS (
    SELECT e.category, pt.price_cents,
           count(t.ticket_id) FILTER (WHERE t.status = 'issued') AS sold,
           count(DISTINCT s.seat_id)                              AS seats
      FROM price_tiers pt
      JOIN events e  USING (event_id)
      JOIN seats s   ON s.section_id = pt.section_id
      LEFT JOIN tickets t ON t.event_id = pt.event_id AND t.seat_id = s.seat_id
     WHERE e.status = 'completed'
     GROUP BY e.category, pt.event_id, pt.section_id, pt.price_cents
), banded AS (
    SELECT *, ntile(4) OVER (PARTITION BY category ORDER BY price_cents) AS price_quartile
      FROM tier_sales
)
SELECT category, price_quartile,
       to_char(min(price_cents) / 100.0, 'FM$990') || '–' || to_char(max(price_cents) / 100.0, 'FM$990') AS price_range,
       round(100.0 * sum(sold) / sum(seats), 1) AS sell_through_pct
  FROM banded
 GROUP BY category, price_quartile
 ORDER BY category, price_quartile;

-- -----------------------------------------------------------------------------
\echo '\n[Q9] Refund watchlist: customers whose refund rate is far above average (min. 4 orders)'
-- -----------------------------------------------------------------------------
WITH per_customer AS (
    SELECT customer_id,
           count(*) FILTER (WHERE status IN ('paid', 'refunded')) AS orders,
           count(*) FILTER (WHERE status = 'refunded')            AS refunds
      FROM orders GROUP BY customer_id
)
SELECT c.customer_id, c.full_name, p.orders, p.refunds,
       round(100.0 * p.refunds / p.orders, 1) AS refund_rate_pct,
       round(100.0 * avg(1.0 * p.refunds / p.orders) OVER () , 1) AS platform_avg_pct
  FROM per_customer p JOIN customers c USING (customer_id)
 WHERE p.orders >= 4
 ORDER BY 1.0 * p.refunds / p.orders DESC, p.orders DESC
 LIMIT 10;

-- -----------------------------------------------------------------------------
\echo '\n[Q10] Sales pace: projected final sell-through for upcoming events, from historical booking curves'
-- -----------------------------------------------------------------------------
WITH upcoming AS (
    SELECT event_id, title, category, sell_through_pct,
           ceil(extract(epoch FROM starts_at - now()) / 86400)::int AS days_out
      FROM v_event_sales
     WHERE status = 'on_sale' AND starts_at > now()
), curve AS (
    -- completed events: what share of final paid orders had arrived N days before showtime?
    SELECT e.category, d.days_out,
           avg(cnt.paid_by::numeric / NULLIF(cnt.final, 0)) AS share_of_final
      FROM events e
     CROSS JOIN (SELECT DISTINCT days_out FROM upcoming) d
     CROSS JOIN LATERAL (
        SELECT count(*) FILTER (WHERE o.paid_at <= e.starts_at - make_interval(days => d.days_out)) AS paid_by,
               count(*) AS final
          FROM orders o WHERE o.event_id = e.event_id AND o.status = 'paid') cnt
     WHERE e.status = 'completed'
     GROUP BY e.category, d.days_out
), benchmark AS (
    SELECT category, avg(sell_through_pct) AS typical_final_pct
      FROM v_event_sales WHERE status = 'completed' GROUP BY category
)
SELECT u.title, u.category, u.days_out,
       u.sell_through_pct                                                  AS sold_pct_now,
       round(100 * c.share_of_final, 1)                                    AS typical_pct_of_sales_done,
       round(LEAST(100, u.sell_through_pct / NULLIF(c.share_of_final, 0)), 1) AS projected_final_pct,
       round(b.typical_final_pct, 1)                                       AS category_typical_pct,
       CASE WHEN u.sell_through_pct / NULLIF(c.share_of_final, 0) >= 95      THEN 'likely sell-out'
            WHEN u.sell_through_pct / NULLIF(c.share_of_final, 0) < b.typical_final_pct - 10 THEN 'behind - promote'
            ELSE 'on pace' END                                             AS outlook
  FROM upcoming u
  JOIN curve c     USING (category, days_out)
  JOIN benchmark b USING (category)
 WHERE c.share_of_final >= 0.15            -- too early to project otherwise
 ORDER BY u.days_out
 LIMIT 12;
