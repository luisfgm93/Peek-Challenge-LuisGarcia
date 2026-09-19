-- ============================================================
-- PART 1 — SQL
-- ============================================================

-- ============================================================
-- HOW TO RUN
-- ============================================================
-- Run each task independently in BigQuery Standard SQL.
--
-- Tasks A and B use configurable date parameters.
-- Task C uses the full available completed-order history.
-- Task D uses configurable launch_date and window_days parameters
-- and returns multiple analytical outputs.

-- ============================================================
-- TASK A — MONTHLY FINANCIALS
-- ============================================================

-- Objective:
-- Return one row per month containing:
-- revenue, completed orders, units sold, AOV,
-- and month-over-month revenue growth.

BEGIN

  DECLARE start_date DATE DEFAULT DATE '2019-02-01';
  DECLARE end_date   DATE DEFAULT DATE '2026-09-01';

  WITH completed_sales AS (
    SELECT
      DATE_TRUNC(DATE(created_at), MONTH) AS month,
      order_id,
      sale_price
    FROM `bigquery-public-data.thelook_ecommerce.order_items`
    WHERE status = 'Complete'
      AND returned_at IS NULL
      AND DATE(created_at) >= start_date
      AND DATE(created_at) < end_date
  ),

  monthly_financials AS (
    SELECT
      month,
      SUM(sale_price) AS revenue,
      COUNT(DISTINCT order_id) AS orders,
      COUNT(*) AS units
    FROM completed_sales
    GROUP BY month
  ),

  with_previous_month AS (
    SELECT
      month,
      revenue,
      orders,
      units,
      LAG(revenue) OVER (ORDER BY month) AS previous_month_revenue
    FROM monthly_financials
  )

  SELECT
    month,
    revenue,
    orders,
    units,
    SAFE_DIVIDE(revenue, orders) AS aov,
    ROUND(SAFE_DIVIDE(revenue - previous_month_revenue,previous_month_revenue) * 100,2) AS mom_revenue_growth
  FROM with_previous_month
  ORDER BY month;

END;

-- ============================================================
-- TASK B — NEW VS RETURNING CUSTOMER MIX
-- ============================================================

-- Objective:
-- Return one row per month containing:
-- active customers, new customers, returning customers,
-- revenue from new customers, revenue from returning customers,
-- and the percentage of revenue from returning customers.


BEGIN

  DECLARE start_date DATE DEFAULT DATE '2019-02-01';
  DECLARE end_date   DATE DEFAULT DATE '2026-09-01';

  WITH completed_sales AS (
    SELECT
      user_id,
      DATE(created_at) AS purchase_date,
      DATE_TRUNC(DATE(created_at), MONTH) AS purchase_month,
      sale_price
    FROM `bigquery-public-data.thelook_ecommerce.order_items`
    WHERE status = 'Complete'
      AND returned_at IS NULL
  ),

  first_purchase AS (
    SELECT
      user_id,
      MIN(purchase_month) AS first_purchase_month
    FROM completed_sales
    GROUP BY user_id
  ),

  reporting_sales AS (
    SELECT
      *
    FROM completed_sales
    WHERE purchase_date >= start_date
      AND purchase_date < end_date
  )

  SELECT
    rs.purchase_month AS month,

    COUNT(DISTINCT rs.user_id) AS active_customers,

    COUNT(DISTINCT CASE
      WHEN rs.purchase_month = fp.first_purchase_month
      THEN rs.user_id
    END) AS new_customers,

    COUNT(DISTINCT CASE
      WHEN rs.purchase_month > fp.first_purchase_month
      THEN rs.user_id
    END) AS returning_customers,

    SUM(CASE
      WHEN rs.purchase_month = fp.first_purchase_month
      THEN rs.sale_price
      ELSE 0
    END) AS revenue_new,

    SUM(CASE
      WHEN rs.purchase_month > fp.first_purchase_month
      THEN rs.sale_price
      ELSE 0
    END) AS revenue_returning,

    ROUND(
    SAFE_DIVIDE(
      SUM(CASE
        WHEN rs.purchase_month > fp.first_purchase_month
        THEN rs.sale_price
        ELSE 0
      END),
      SUM(rs.sale_price)) * 100, 2)
     AS pct_revenue_from_returning

  FROM reporting_sales rs

  JOIN first_purchase fp
    ON rs.user_id = fp.user_id

  GROUP BY month
  ORDER BY month;

END;

-- ============================================================
-- TASK C — 90-DAY CHURN
-- ============================================================

-- Objective:
-- Return one row per fully observable month containing:
-- active customers, customers with no completed order
-- in the following 90 days, and the 90-day churn rate.

WITH completed_orders AS (
  SELECT
    user_id,
    order_id,
    DATE(MIN(created_at)) AS order_date
  FROM `bigquery-public-data.thelook_ecommerce.order_items`
  WHERE status = 'Complete'
    AND returned_at IS NULL
  GROUP BY
    user_id,
    order_id
),

observation_end AS (
  SELECT
    MAX(order_date) AS max_order_date
  FROM completed_orders
),

customer_month_activity AS (
  SELECT
    user_id,
    DATE_TRUNC(order_date, MONTH) AS month,
    MAX(order_date) AS last_order_date
  FROM completed_orders
  GROUP BY
    user_id,
    month
),

next_order AS (
  SELECT
    cma.user_id,
    cma.month,
    cma.last_order_date,
    MIN(co.order_date) AS next_order_date
  FROM customer_month_activity cma

  LEFT JOIN completed_orders co
    ON cma.user_id = co.user_id
    AND co.order_date > cma.last_order_date

  GROUP BY
    cma.user_id,
    cma.month,
    cma.last_order_date
),

with_churn_flag AS (
  SELECT
    nxo.user_id,
    nxo.month,
    nxo.last_order_date,
    nxo.next_order_date,

    CASE

      -- Insufficient future data to determine churn
      WHEN DATE_ADD(nxo.last_order_date, INTERVAL 90 DAY)
           > oe.max_order_date
      THEN NULL

      -- No subsequent completed order despite a fully observable window
      WHEN nxo.next_order_date IS NULL
      THEN 1

      -- Customer returned, but after the 90-day window
      WHEN DATE_DIFF(
        nxo.next_order_date,
        nxo.last_order_date,
        DAY
      ) > 90
      THEN 1

      -- Customer returned within 90 days
      ELSE 0

    END AS churned_90d

  FROM next_order nxo
  CROSS JOIN observation_end oe
)

SELECT
  month,

  COUNT(DISTINCT user_id) AS active_customers,

  COUNTIF(churned_90d = 1) AS churned_customers_90d,

ROUND(
  SAFE_DIVIDE(
    COUNTIF(churned_90d = 1),
    COUNT(DISTINCT user_id)
  ) * 100,
  2
) AS churn_rate_90d

FROM with_churn_flag

GROUP BY month

-- Exclude months where any customer lacks a complete
-- 90-day observation window.
HAVING COUNTIF(churned_90d IS NULL) = 0

ORDER BY month;

-- ============================================================
-- TASK D — PRODUCT CHANGE IMPACT
-- Hypothetical policy: Free shipping on orders over $100
-- Launch date: 2022-01-15
-- ============================================================

-- Objective:
-- Simulate how the impact of the hypothetical policy could be
-- evaluated using AOV, monthly revenue, gross profit, traffic source,
-- and order-value behavior around the $100 threshold.
--
-- Important:
-- The dataset does not contain the actual intervention.
-- Results are descriptive and should not be interpreted as causal.

BEGIN

  DECLARE launch_date DATE DEFAULT DATE '2022-01-15';
  DECLARE window_days INT64 DEFAULT 90;

  -- ----------------------------------------------------------
  -- D1 — MONTHLY KPI IMPACT BY TRAFFIC SOURCE
  -- ----------------------------------------------------------

  WITH order_financials AS (
    SELECT
      oi.order_id,
      oi.user_id,
      DATE(MIN(oi.created_at)) AS order_date,
      SUM(oi.sale_price) AS order_revenue,
      SUM(ii.cost) AS order_cogs,
      SUM(oi.sale_price) - SUM(ii.cost) AS gross_profit
    FROM `bigquery-public-data.thelook_ecommerce.order_items` oi

    LEFT JOIN `bigquery-public-data.thelook_ecommerce.inventory_items` ii
      ON oi.inventory_item_id = ii.id

    WHERE oi.status = 'Complete'
      AND oi.returned_at IS NULL

    GROUP BY
      oi.order_id,
      oi.user_id
  ),

  analysis_window AS (
    SELECT
      ord.*,
      u.traffic_source,

      CASE
        WHEN ord.order_date < launch_date THEN 'Pre'
        ELSE 'Post'
      END AS policy_period

    FROM order_financials ord

    LEFT JOIN `bigquery-public-data.thelook_ecommerce.users` u
      ON ord.user_id = u.id

    WHERE ord.order_date >= DATE_SUB(launch_date, INTERVAL window_days DAY)
      AND ord.order_date < DATE_ADD(launch_date, INTERVAL window_days DAY)
  )

  SELECT
    DATE_TRUNC(order_date, MONTH) AS month,
    traffic_source,
    policy_period,
    COUNT(*) AS orders,
    SUM(order_revenue) AS total_revenue,
    AVG(order_revenue) AS aov,
    SUM(gross_profit) AS gross_profit

  FROM analysis_window

  GROUP BY
    month,
    traffic_source,
    policy_period

  ORDER BY
    month,
    traffic_source,
    policy_period;


  -- ----------------------------------------------------------
  -- D2 — ORDER-VALUE THRESHOLD ANALYSIS
  -- ----------------------------------------------------------

  WITH order_financials AS (
    SELECT
      oi.order_id,
      oi.user_id,
      DATE(MIN(oi.created_at)) AS order_date,
      SUM(oi.sale_price) AS order_revenue,
      SUM(ii.cost) AS order_cogs,
      SUM(oi.sale_price) - SUM(ii.cost) AS gross_profit
    FROM `bigquery-public-data.thelook_ecommerce.order_items` oi

    LEFT JOIN `bigquery-public-data.thelook_ecommerce.inventory_items` ii
      ON oi.inventory_item_id = ii.id

    WHERE oi.status = 'Complete'
      AND oi.returned_at IS NULL

    GROUP BY
      oi.order_id,
      oi.user_id
  ),

  threshold_window AS (
    SELECT
      *,

      CASE
        WHEN order_date < launch_date THEN 'Pre'
        ELSE 'Post'
      END AS policy_period,

      CASE
        WHEN order_revenue < 75 THEN 'Under $75'
        WHEN order_revenue <= 100 THEN '$75-$100'
        WHEN order_revenue <= 125 THEN '$100-$125'
        ELSE 'Over $125'
      END AS order_value_band

    FROM order_financials

    WHERE order_date >= DATE_SUB(launch_date, INTERVAL window_days DAY)
      AND order_date < DATE_ADD(launch_date, INTERVAL window_days DAY)
  )

  SELECT
    policy_period,
    order_value_band,
    COUNT(*) AS orders,

    SAFE_DIVIDE(
      COUNT(*),
      SUM(COUNT(*)) OVER (PARTITION BY policy_period)
    ) AS pct_of_orders,

    SUM(order_revenue) AS revenue,
    AVG(order_revenue) AS aov,
    SUM(gross_profit) AS gross_profit

  FROM threshold_window

  GROUP BY
    policy_period,
    order_value_band

  ORDER BY
    policy_period,
    CASE order_value_band
      WHEN 'Under $75' THEN 1
      WHEN '$75-$100' THEN 2
      WHEN '$100-$125' THEN 3
      WHEN 'Over $125' THEN 4
    END;

END;
