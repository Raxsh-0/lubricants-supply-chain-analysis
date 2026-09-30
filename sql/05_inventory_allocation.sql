/* ============================================================================
   05 - IS THE PROBLEM TOO LITTLE STOCK, OR STOCK IN THE WRONG PLACE?
   ----------------------------------------------------------------------------
   Script 04 showed that buying one extra week of cover pays for itself if we
   recover as little as 8.4% of the volume we currently miss. That looks like
   an obvious "buy more inventory" decision - which should make you suspicious.
   If it were that easy, the business would have done it already.

   So test the alternative first: when a depot could not fill an order, did the
   network actually hold that SKU somewhere else that same week? If it did, the
   problem is allocation, not quantity, and buying more stock would just put
   more stock in the wrong place.

   This script also tests the standard "cut the slow-moving tail" playbook, and
   rejects it - which is a result worth presenting, not hiding.
   ========================================================================= */

USE LubeSupplyChain;
GO

/* Reusable ABC classification. Defined once here so the SQL and the Power BI
   model cannot drift apart. Volume-ranked, 80/15/5 cut. */
IF OBJECT_ID('dbo.vw_sku_abc') IS NOT NULL DROP VIEW dbo.vw_sku_abc;
GO
CREATE VIEW dbo.vw_sku_abc AS
WITH vol AS (
    SELECT sku_id, SUM(delivered_qty_l) AS delivered_l
    FROM dbo.fact_order_line
    GROUP BY sku_id
),
ranked AS (
    SELECT sku_id, delivered_l,
           SUM(delivered_l) OVER (ORDER BY delivered_l DESC
                                  ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
           / SUM(delivered_l) OVER ()                    AS cumulative_share,
           ROW_NUMBER() OVER (ORDER BY delivered_l DESC) AS volume_rank
    FROM vol
)
SELECT sku_id, delivered_l, volume_rank,
       CAST(cumulative_share AS DECIMAL(9,6)) AS cumulative_share,
       CASE WHEN cumulative_share <= 0.80 THEN 'A'
            WHEN cumulative_share <= 0.95 THEN 'B'
            ELSE 'C' END AS abc_class
FROM ranked;
GO

/* ===========================================================================
   5.1  THE CENTREPIECE QUERY
   For every week in which a depot failed to fill an order for a SKU, ask:
   how much of that SKU was sitting in the OTHER depots that same week?

   How to read it: "coverable elsewhere" means the rest of the network held at
   least as many litres of that exact SKU, in that exact week, as the depot was
   short. It is a deliberately strict test - same SKU, same week, not "some
   time that month".
   ======================================================================== */
WITH shortfall AS (
    SELECT o.sku_id,
           o.depot_id,
           /* snap the order date back to its Monday so it lines up with the
              weekly stock ledger */
           DATEADD(day, -((DATEPART(weekday, o.order_date) + @@DATEFIRST - 2) % 7),
                   o.order_date)                              AS week_start_date,
           SUM(o.ordered_qty_l - o.delivered_qty_l)           AS shortfall_l
    FROM dbo.fact_order_line o
    WHERE o.fail_reason IN ('DEPOT_STOCKOUT','PLANT_DELAY')
    GROUP BY o.sku_id, o.depot_id,
             DATEADD(day, -((DATEPART(weekday, o.order_date) + @@DATEFIRST - 2) % 7), o.order_date)
),
network_stock AS (
    SELECT sku_id, week_start_date, SUM(closing_stock_l) AS network_stock_l
    FROM dbo.fact_depot_stock_weekly
    GROUP BY sku_id, week_start_date
)
SELECT
    COUNT(*)                                                                     AS shortfall_events,
    CAST(SUM(s.shortfall_l) / 1000.0 AS DECIMAL(12,0))                           AS shortfall_kl,
    CAST(100.0 * SUM(CASE WHEN n.network_stock_l - own.closing_stock_l >= s.shortfall_l
                          THEN 1.0 ELSE 0.0 END) / COUNT(*) AS DECIMAL(5,1))     AS pct_events_coverable_elsewhere,
    CAST(100.0 * SUM(CASE WHEN n.network_stock_l - own.closing_stock_l >= s.shortfall_l
                          THEN s.shortfall_l ELSE 0 END)
         / NULLIF(SUM(s.shortfall_l), 0) AS DECIMAL(5,1))                        AS pct_volume_coverable_elsewhere
FROM shortfall s
JOIN network_stock n              ON n.sku_id = s.sku_id AND n.week_start_date = s.week_start_date
JOIN dbo.fact_depot_stock_weekly own ON own.sku_id   = s.sku_id
                                    AND own.depot_id = s.depot_id
                                    AND own.week_start_date = s.week_start_date;

/* Same test, split by depot: which depots are being starved by the allocation
   rule rather than by a genuine shortage? */
WITH shortfall AS (
    SELECT o.sku_id, o.depot_id,
           DATEADD(day, -((DATEPART(weekday, o.order_date) + @@DATEFIRST - 2) % 7), o.order_date) AS week_start_date,
           SUM(o.ordered_qty_l - o.delivered_qty_l) AS shortfall_l
    FROM dbo.fact_order_line o
    WHERE o.fail_reason IN ('DEPOT_STOCKOUT','PLANT_DELAY')
    GROUP BY o.sku_id, o.depot_id,
             DATEADD(day, -((DATEPART(weekday, o.order_date) + @@DATEFIRST - 2) % 7), o.order_date)
),
network_stock AS (
    SELECT sku_id, week_start_date, SUM(closing_stock_l) AS network_stock_l
    FROM dbo.fact_depot_stock_weekly GROUP BY sku_id, week_start_date
)
SELECT
    d.depot_name,
    CAST(SUM(s.shortfall_l) / 1000.0 AS DECIMAL(12,0))                       AS shortfall_kl,
    CAST(100.0 * SUM(CASE WHEN n.network_stock_l - own.closing_stock_l >= s.shortfall_l
                          THEN s.shortfall_l ELSE 0 END)
         / NULLIF(SUM(s.shortfall_l), 0) AS DECIMAL(5,1))                    AS pct_volume_coverable_elsewhere
FROM shortfall s
JOIN network_stock n              ON n.sku_id = s.sku_id AND n.week_start_date = s.week_start_date
JOIN dbo.fact_depot_stock_weekly own ON own.sku_id = s.sku_id AND own.depot_id = s.depot_id
                                    AND own.week_start_date = s.week_start_date
JOIN dbo.dim_depot d              ON d.depot_id = s.depot_id
GROUP BY d.depot_name
ORDER BY shortfall_kl DESC;

/* ---------------------------------------------------------------------------
   5.2  Corroboration: the replenishment plan is wrong in BOTH directions
   A depot that is chronically under-supplied has a capacity problem. A network
   that is under-supplied 14% of the time and over-supplied 12% of the time has
   a forecasting problem - the plan is stale, not short.
   ------------------------------------------------------------------------ */
SELECT
    CAST(100.0 * AVG(CASE WHEN receipts_l < planned_receipts_l * 0.90 THEN 1.0 ELSE 0.0 END)
         AS DECIMAL(5,2))                                                       AS pct_weeks_under_supplied,
    CAST(100.0 * AVG(CASE WHEN receipts_l > planned_receipts_l * 1.10 THEN 1.0 ELSE 0.0 END)
         AS DECIMAL(5,2))                                                       AS pct_weeks_over_supplied,
    CAST(100.0 * SUM(receipts_l) / NULLIF(SUM(planned_receipts_l), 0) AS DECIMAL(5,1)) AS receipts_pct_of_plan
FROM dbo.fact_depot_stock_weekly;

/* Same split by depot - the allocation bias should show up here as a pattern
   by distance from the plant, not as random noise. */
SELECT
    d.depot_name, d.distance_km,
    CAST(100.0 * SUM(s.receipts_l) / NULLIF(SUM(s.planned_receipts_l), 0) AS DECIMAL(5,1)) AS receipts_pct_of_plan,
    CAST(100.0 * AVG(CASE WHEN s.receipts_l < s.planned_receipts_l * 0.90 THEN 1.0 ELSE 0.0 END)
         AS DECIMAL(5,2))                                                       AS pct_weeks_under_supplied
FROM dbo.fact_depot_stock_weekly s
JOIN dbo.dim_depot d ON d.depot_id = s.depot_id
GROUP BY d.depot_name, d.distance_km
ORDER BY receipts_pct_of_plan;

/* ===========================================================================
   5.3  Now test the OTHER standard remedy: cut the slow-moving tail
   ======================================================================== */
SELECT
    abc_class,
    COUNT(*)                                                                       AS skus,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1))                 AS pct_of_skus,
    CAST(SUM(delivered_l) / 1000.0 AS DECIMAL(12,0))                               AS delivered_kl,
    CAST(100.0 * SUM(delivered_l) / SUM(SUM(delivered_l)) OVER () AS DECIMAL(5,1)) AS pct_of_volume
FROM dbo.vw_sku_abc
GROUP BY abc_class
ORDER BY pct_of_volume DESC;

/* ---------------------------------------------------------------------------
   5.4  What the tail ties up, and what it earns
   The tail does carry more cover than the fast movers - but before cutting it,
   check the return. Gross margin earned per rupee of stock held per year is
   the honest test, and it is the column that decides the recommendation.
   ------------------------------------------------------------------------ */
WITH pair AS (
    SELECT s.depot_id, s.sku_id,
           AVG(s.closing_stock_l) AS avg_stock_l,
           SUM(s.dispatches_l)    AS dispatched_l,
           SUM(s.writeoff_l)      AS writeoff_l
    FROM dbo.fact_depot_stock_weekly s
    GROUP BY s.depot_id, s.sku_id
)
SELECT
    a.abc_class,
    COUNT(*)                                                                         AS depot_sku_pairs,
    CAST(SUM(p.avg_stock_l * k.std_cost_inr_per_l) / 10000000.0 AS DECIMAL(12,2))    AS stock_value_cr,
    CAST(SUM(p.dispatched_l * (k.list_price_inr_per_l - k.std_cost_inr_per_l))
         / 3.0 / 10000000.0 AS DECIMAL(12,2))                                        AS gross_margin_cr_per_yr,
    CAST(SUM(p.dispatched_l * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 3.0
         / NULLIF(SUM(p.avg_stock_l * k.std_cost_inr_per_l), 0) AS DECIMAL(8,1))     AS margin_per_rupee_of_stock,
    CAST(SUM(p.writeoff_l) / 1000.0 AS DECIMAL(12,1))                                AS aged_writeoff_kl
FROM pair p
JOIN dbo.vw_sku_abc a ON a.sku_id = p.sku_id
JOIN dbo.dim_sku    k ON k.sku_id = p.sku_id
GROUP BY a.abc_class
ORDER BY a.abc_class;

/* ---------------------------------------------------------------------------
   5.5  Weeks of cover by depot and class - where cover is genuinely excessive
   ------------------------------------------------------------------------ */
SELECT
    d.depot_name,
    a.abc_class,
    CAST(SUM(s.closing_stock_l) / NULLIF(SUM(s.dispatches_l), 0) AS DECIMAL(8,2)) AS weeks_of_cover,
    CAST(SUM(s.closing_stock_l * k.std_cost_inr_per_l) / 156.0 / 10000000.0
         AS DECIMAL(12,2))                                                        AS avg_stock_value_cr
FROM dbo.fact_depot_stock_weekly s
JOIN dbo.vw_sku_abc a ON a.sku_id   = s.sku_id
JOIN dbo.dim_sku    k ON k.sku_id   = s.sku_id
JOIN dbo.dim_depot  d ON d.depot_id = s.depot_id
GROUP BY d.depot_name, a.abc_class
ORDER BY weeks_of_cover DESC;

/* ---------------------------------------------------------------------------
   5.6  Does the tail hurt service? (the other argument for cutting it)
   ------------------------------------------------------------------------ */
SELECT
    a.abc_class,
    COUNT(*)                                                                    AS order_lines,
    CAST(100.0 * AVG(CAST(o.in_full_flag AS DECIMAL(5,2))) AS DECIMAL(5,2))     AS in_full_pct,
    CAST(100.0 * AVG(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))               AS otif_pct
FROM dbo.fact_order_line o
JOIN dbo.vw_sku_abc a ON a.sku_id = o.sku_id
GROUP BY a.abc_class
ORDER BY a.abc_class;

/* ---------------------------------------------------------------------------
   5.7  The named list - the depot/SKU pairs that genuinely hold too much
   Not a class-wide cull: a specific, checkable list of what to trim.
   ------------------------------------------------------------------------ */
SELECT TOP 25
    d.depot_name, k.sku_id, k.sku_name, k.segment_code, a.abc_class,
    CAST(AVG(s.closing_stock_l) AS DECIMAL(12,0))                                   AS avg_stock_l,
    CAST(SUM(s.dispatches_l) / 156.0 AS DECIMAL(12,1))                              AS avg_weekly_offtake_l,
    CAST(AVG(s.closing_stock_l) / NULLIF(SUM(s.dispatches_l) / 156.0, 0)
         AS DECIMAL(10,1))                                                          AS weeks_of_cover,
    CAST(AVG(s.closing_stock_l) * k.std_cost_inr_per_l / 100000.0 AS DECIMAL(12,2)) AS stock_value_lakh
FROM dbo.fact_depot_stock_weekly s
JOIN dbo.dim_sku    k ON k.sku_id   = s.sku_id
JOIN dbo.dim_depot  d ON d.depot_id = s.depot_id
JOIN dbo.vw_sku_abc a ON a.sku_id   = s.sku_id
GROUP BY d.depot_name, k.sku_id, k.sku_name, k.segment_code, a.abc_class, k.std_cost_inr_per_l
HAVING SUM(s.dispatches_l) > 0
ORDER BY weeks_of_cover DESC;
GO
