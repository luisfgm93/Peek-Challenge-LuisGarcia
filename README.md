# Peek Product & BI Analyst Data Challenge by Luis Garcia

## Overview

This repository contains my solution for the Peek Product & BI Analyst Data Challenge using the public BigQuery dataset:

`bigquery-public-data.thelook_ecommerce`

The analysis focuses on:

- Monthly financial performance
- New vs returning customer behavior
- 90-day customer churn
- A hypothetical free-shipping policy for orders over $100
- Supporting product and customer segmentation analysis
- AI & Analytics

The SQL is written in BigQuery Standard SQL and is designed to be readable, reproducible, and easy to modify through parameterized date logic where applicable.

Prior to starting the tasks, initial data familiarization was performed. The row counts of the main tables were reviewed to understand their relative size and likely grain. This helped identify which tables represented high-volume event or line-item data versus lower-grain entities such as users, products, and orders. This is presented below as Name_RowCount:

- events_2425353
- inventory_items_488014
- order_items_180858
- orders_124581
- users_100000
- products_29120

A simplified database schema was created during the initial data-familiarization stage to understand the relevant tables, their grain, and the relationships used throughout the analysis.

## Analysis & Visualization

[View the exported dashboard PDF](analysis/LuisGarciaDataChallenge.pdf)

The interactive Looker Studio dashboard is available here:

[Open the Looker Studio dashboard](https://datastudio.google.com/reporting/cb982488-0cdd-4ac7-a031-011ac12e133a)

The dashboard includes the three Part 2 visuals selected for the final analysis:

- Revenue and Orders Month Over Month
- New vs Returning Revenue Mix by Month
- 90-Day Churn Rate vs Revenue

It also includes the optional stretch analysis:

- 90-Day Churn Rate by Traffic Source

The final dashboard pages address three Part 2 discussion areas:

- Definitions and alternative definitions
- Most important trend for leadership
- Business initiative and success metrics

## How to Run

Run each task independently from `/sql/part1_queries.sql`.

Tasks A and B use configurable date parameters.
Task C uses the full available completed-order history.
Task D uses configurable `launch_date` and `window_days` parameters and returns multiple analytical outputs.

All queries use BigQuery Standard SQL. No credentials or private datasets are required.

### Percentage Conventions

For readability in the query outputs:

- Task A `mom_revenue_growth` is returned on a **0–100 percentage scale** and rounded to two decimal places.
- Task B `pct_revenue_from_returning` is returned on a **0–100 percentage scale** and rounded to two decimal places.
- Task C `churn_rate_90d` is returned on a **0–100 percentage scale** and rounded to two decimal places.
- Task D `pct_of_orders` is returned as a **0–1 fractional value** and can be formatted as a percentage in the visualization layer.

For example, `12.39` in Tasks A–C represents **12.39%**, while `0.1239` in Task D represents **12.39%**.


## Repository Structure

```text
/sql/
  part1_queries.sql

/analysis/
  LuisGarciaDataChallenge.pdf
  dashboard_link.md

README.md
```

# Task A — Monthly Financials

## Definitions and Assumptions

A completed sale is defined as:

`status = 'Complete' AND returned_at IS NULL`

Revenue is calculated as:

`SUM(order_items.sale_price)`

Monthly reporting uses:

`DATE_TRUNC(DATE(created_at), MONTH)`

One row in `order_items` represents one item, so units sold are calculated using:

`COUNT(*)`

Completed orders are calculated using:

`COUNT(DISTINCT order_id)`

Average Order Value (AOV) is calculated as:

`Monthly Revenue / Completed Orders`

Month-over-month (MoM) revenue growth is calculated as:

`(Current Month Revenue - Previous Month Revenue) / Previous Month Revenue`

`SAFE_DIVIDE(numerator, denominator)` is used instead of the standard division operator (`/`) for calculated ratios so undefined ratios return `NULL` rather than causing an error.

The first and last observed boundary months are excluded to avoid potentially incomplete month-to-month comparisons.

A `NULL` result is intentionally preserved rather than replaced with zero because zero and "not calculable" have different business meanings.


## Date Range

Reporting start date:

`2019-02-01` — inclusive

Reporting end date:

`2026-09-01` — exclusive

The first and last months of the dataset are excluded to avoid potentially incomplete monthly comparisons, as January data starts on the 5th and September data ends on the 19th.

## Development Notes

The query was broken into separate CTEs so that each stage has one clear responsibility: define the valid sales population, aggregate to monthly grain, calculate the prior-month comparison, and then derive the final KPIs.


### Step 1 — `completed_sales`

The `completed_sales` CTE creates the base dataset used by the rest of the query.

It:

- filters to completed, non-returned sales
- applies the reporting date range
- converts `created_at` to monthly grain
- keeps only the fields needed downstream: `month`, `order_id`, and `sale_price`

This CTE centralizes the filtering rules so they do not need to be repeated in later stages.


### Step 2 — `monthly_financials`

The `monthly_financials` CTE aggregates the filtered line-item data to one row per month.

It calculates:

**Revenue**

`SUM(sale_price)`

**Completed Orders**

`COUNT(DISTINCT order_id)`

**Units Sold**

`COUNT(*)`

`COUNT(*)` is used for units because `order_items` is at line-item grain, so each retained row represents one item sold.

At this stage, the dataset has been reduced from transaction-level data to monthly financial totals.


### Step 3 — `with_previous_month`

The `with_previous_month` CTE adds the previous month's revenue using:

`LAG(revenue) OVER (ORDER BY month)`

`LAG()` is applied after monthly aggregation so that the previous value represents the prior month's total revenue rather than the previous transaction.

### Step 4 — Final output

The final `SELECT` returns the requested monthly metrics:

- month
- revenue
- completed orders
- units sold
- AOV
- month-over-month revenue growth

Average Order Value is calculated as:

`SAFE_DIVIDE(revenue, orders)`

Month-over-month revenue growth is calculated as:

`SAFE_DIVIDE(revenue - previous_month_revenue, previous_month_revenue)`

`SAFE_DIVIDE()` is used instead of the standard division operator to prevent a division-by-zero error. If the denominator is zero, BigQuery returns `NULL` rather than failing the query.

A `NULL` is preferable to replacing the value with zero because zero and "not calculable" have different business meanings.

# Task B — New vs Returning Customer Mix

## Definitions and Assumptions

A completed sale is defined as:

`status = 'Complete' AND returned_at IS NULL`

An **active customer** is a unique customer with at least one completed purchase during the month.

A **new customer** is a customer whose first-ever completed order in the available dataset occurs during that calendar month.

A customer is considered new for the entirety of their first-purchase calendar month.

A **returning customer** is an active customer whose first-ever completed order in the available dataset occurred in a previous calendar month.

First purchase refers to the customer's first-ever completed order observed in the available dataset.

Because the dataset has a finite historical starting point, customers appearing early in the dataset may have purchased before the observable period.

First purchase is calculated using the full available completed-sales history before the reporting-period filter is applied. This prevents customers with earlier purchases outside the displayed reporting period from being incorrectly classified as new.

Revenue from new and returning customers follows the same monthly customer classification.

### Alternative Definition Considered

An alternative approach would be to classify a customer as new for the first **30 days following their first purchase**, rather than for their first calendar month.

For example, a customer making their first purchase late in January would remain "new" into February under a 30-day definition.

This may be more appropriate for lifecycle analysis because each customer receives the same acquisition window regardless of the day they first purchased.

The calendar-month definition was selected because the requested output is monthly and provides a consistent reporting definition.

## Date Range

Reporting start date:

`2019-02-01` — inclusive

Reporting end date:

`2026-09-01` — exclusive

The displayed reporting period matches Task A.

However, first-purchase classification is calculated using the full available completed-sales history before the reporting-period filter is applied.

## Development Notes

The query is structured into three CTEs so each stage handles a separate part of the customer-classification logic.

### Step 1 — `completed_sales`

Creates the base population of completed, non-returned purchases and derives:

- `purchase_date`
- `purchase_month`
- `sale_price`

The full available completed-sales history is retained here so first purchase can be identified correctly.

### Step 2 — `first_purchase`

Calculates each customer's first-ever observed purchase month using:

`MIN(purchase_month)`

This CTE defines the reference point used to classify customers as new or returning.

### Step 3 — `reporting_sales`

Applies the reporting window:

`2019-02-01` inclusive through `2026-09-01` exclusive.

The date filter is applied only after first-purchase history is established, so earlier purchases are not lost when determining customer status.

### Step 4 — Final output

The final query joins `reporting_sales` to `first_purchase` and calculates:

- active customers
- new customers
- returning customers
- revenue from new customers
- revenue from returning customers
- percentage of revenue from returning customers

A customer is classified as new when:

`purchase_month = first_purchase_month`

and returning when:

`purchase_month > first_purchase_month`


# Task C — 90-Day Churn

## Definitions and Assumptions

A completed order is defined as:

`status = 'Complete' AND returned_at IS NULL`

An **active customer** is a unique customer with at least one completed order during the month.

For customers with multiple completed orders within the same month, the customer's **last completed order in that month** is used as the starting point for the subsequent 90-day inactivity window.

A customer is considered churned if no completed order occurs within the following 90 days.

A customer returning exactly 90 days later is considered to have returned within the 90-day window. Churn therefore requires more than 90 days of inactivity.

A `LEFT JOIN` is used when searching for the next completed order so customers who never purchase again remain in the analysis.

Customers for whom the dataset does not contain a full subsequent 90-day observation window are considered **right-censored**.

Months containing right-censored customers are excluded from the final monthly churn output.

This ensures that the displayed `active_customers` value is also the denominator used in the churn-rate calculation.

A 90-day inactivity threshold is a business definition rather than proof of permanent customer loss. Customers with naturally long purchase cycles may return after the 90-day period.

90-day churn is defined as an active customer making no subsequent completed order within 90 days of their last completed order in that month. Customers may still return after the 90-day window.

## Date Range

The full available completed-order history is used to determine customer activity and subsequent purchases.

The maximum observed completed-order date is used to determine whether a customer has a complete 90-day follow-up window.

Months containing any customers without a complete 90-day observation window are excluded from the final output.

## Development Notes

The query is structured into separate CTEs so each stage handles one part of the churn logic: define completed orders, establish the observable data window, identify monthly customer activity, find the next purchase, classify churn, and aggregate the final rate.

### Step 1 — `completed_orders`

Creates the base population of completed, non-returned orders by aggregating `order_items` to order-level grain.

Each `user_id` / `order_id` combination is reduced to one order date using `DATE(MIN(created_at))`.

`order_items` is used to remain consistent with the challenge's completed-sale convention while still analyzing churn at order level.

### Step 2 — `observation_end`

Finds the latest observable completed-order date using:

`MAX(order_date)`

This date is used to determine whether each customer has a complete 90-day follow-up window.

### Step 3 — `customer_month_activity`

Aggregates activity to one row per customer per active month.

`MAX(order_date)` identifies the customer's last completed order in that month, which becomes the starting point for the 90-day inactivity window.

### Step 4 — `next_order`

Finds the customer's nearest completed order after `last_order_date`.

A `LEFT JOIN` is used so customers who never purchase again remain in the analysis.

`MIN(co.order_date)` identifies the nearest subsequent completed order.

### Step 5 — `with_churn_flag`

Classifies each customer-month observation as:

- `0` — returned within 90 days
- `1` — returned after more than 90 days, or did not return during a fully observable window
- `NULL` — insufficient future data to observe the full 90-day window

The `NULL` classification prevents right-censored customers from being incorrectly labeled as churned.

### Step 6 — Final output

The final query aggregates results to monthly grain and calculates:

- active customers
- churned customers
- 90-day churn rate

`HAVING COUNTIF(churned_90d IS NULL) = 0`

excludes months containing right-censored observations so the displayed active-customer count is also the churn-rate denominator.

The churn rate is calculated as:

`churned_customers_90d / active_customers`

# Task D — Product Change Impact

## Definitions and Assumptions

The hypothetical policy is:

**Free shipping for orders over $100, beginning January 15, 2022.**

The dataset does not contain the actual policy intervention, so results are descriptive rather than causal.

A completed sale is defined as:

`status = 'Complete' AND returned_at IS NULL`

Because policy eligibility depends on total basket value, `order_items` is first aggregated to order-level grain.

**Order Revenue**

`SUM(sale_price) by order_id`

**Order Cost Of Goods Sold(COGS)**

`SUM(inventory_items.cost) by order_id`

**Gross Profit**

`Order Revenue - Order COGS`

Because the policy specifies orders **over $100**, an order must satisfy:

`order_revenue > 100`

An order totaling exactly $100 is therefore treated as non-eligible.

`traffic_source` is used as the selected customer segment.

Order-value bands around the $100 threshold are used as a proxy for possible basket behavior:

- Under $75
- $75–$100
- $100–$125
- Over $125

Gross profit does not include shipping or fulfillment expenses because those fields are unavailable in the dataset.
A real evaluation would require additional fields such as actual shipping fees/costs, exposure to the policy, promotions, experimental/control assignment, and potentially customer sentiment.

## Date Range

Hypothetical launch date:

`2022-01-15`

Analysis window:

`90 days before and 90 days after the hypothetical launch date`

A symmetric window was selected to reduce differences caused by unequal observation periods and longer-term business trends.


## Impact Analysis Approach

Because the free-shipping feature is hypothetical and is not actually present in the dataset, I made the following assumptions:

- The policy applies to orders with total order revenue greater than $100.
- January 15, 2022 is treated as the hypothetical launch date.
- A symmetric 90-day pre/post window is used for comparison.
- `traffic_source` is used as the selected customer segment.
- Order-value bands around $100 are used as a proxy for possible changes in basket behavior.
- Gross profit is calculated as revenue minus product COGS and does not include shipping or fulfillment costs.

To evaluate the feature properly in a real business setting, I would also need:

- shipping fee charged to the customer
- actual shipping and fulfillment cost
- whether an order qualified for free shipping
- whether the customer was exposed to the offer
- experiment or control-group assignment
- discounts and promotional activity
- marketing campaign data
- customer sentiment or satisfaction data

The SQL analysis is structured around two views:

1. A pre/post KPI analysis measuring monthly revenue, AOV, gross profit, order volume, and traffic-source performance.
2. A threshold analysis comparing order-value bands around $100 to look for possible changes in basket behavior near the eligibility cutoff.

Because the feature was not actually implemented in the dataset, the purpose of the analysis is to demonstrate how I would structure and measure the impact of a product change using SQL rather than estimate a true causal effect.

## Development Notes

Task D produces two outputs: a monthly KPI view by traffic source and a threshold analysis around the $100 cutoff.

### Step 1 — `order_financials`

Aggregates `order_items` to one row per order because the hypothetical policy applies to total order value, not individual item prices.

It calculates:

- order revenue
- order COGS
- gross profit

`inventory_items` is joined using `inventory_item_id` to obtain product cost.

### Step 2 — D1: `analysis_window`

Creates the 90-day pre/post analysis window around `2022-01-15`.

It also:

- joins `users` to add `traffic_source`
- classifies each order as `Pre` or `Post`

The final D1 query aggregates by month, traffic source, and policy period to calculate:

- orders
- total revenue
- AOV
- gross profit

### Step 3 — D2: `threshold_window`

Uses the same 90-day pre/post window but groups orders into value bands around the $100 policy threshold:

- Under $75
- $75–$100
- $100–$125
- Over $125

This allows comparison of order behavior immediately below and above the hypothetical cutoff.

### Step 4 — Final threshold output

The D2 query calculates:

- order count
- percentage of orders
- revenue
- AOV
- gross profit

for each value band and policy period.

## Key Recommendations

Based on the dashboard findings:

1. **Test a second-purchase retention program for first-time customers** with the goal of encouraging a second completed order within 90 days.
2. **Start the retention test broadly across acquisition channels** because the 90-day non-repeat rate is consistently high across traffic sources rather than isolated to one channel.
3. **Measure the initiative with a holdout/control design where possible**, using 90-day repeat purchase rate as the primary KPI and returning-revenue share, time to second purchase, AOV, and gross profit as secondary or guardrail metrics.

## AI & Analytics

I used AI primarily as a **SQL copilot** throughout the challenge.

### How I used AI

- Helped create an initial database schema during data familiarization.
- Checked BigQuery syntax and function usage.
- Reviewed CTE structure and query readability.
- Explored alternative query patterns when I wanted to simplify or optimize a query while preserving the same business logic.


### Example Prompt

> Review this BigQuery SQL for 90-day churn. Check the syntax, join logic, date calculations, and right-censoring logic. Confirm whether the query matches the intended definition: a customer is churned if they do not place another completed order within 90 days of their last completed order in the month.

### Validation Approach

I treated AI suggestions as **assistance, not final answers**.

- I validated the diagram against the actual BigQuery tables, column definitions, and joins before using those relationships in the analysis.
- I ran all SQL in BigQuery and reviewed the actual results.
- I compared the logic against the definitions in the challenge brief.
- I checked whether alternative SQL approaches produced comparable outputs before adopting them.
- I investigated unexpected results rather than assuming the query was correct. For example, the unusually high 90-day churn rate led me to recheck both the SQL semantics and the underlying business definition.

