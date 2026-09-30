/* ============================================================================
   06 - WHAT BREAKS FIRST IF DEMAND GROWS?
   ----------------------------------------------------------------------------
   Business question: the Indian lubricants market is growing about 3% a year,
   and a good festive quarter can put 40% more through a depot in a single
   week. If volume rises, which part of the network runs out of capacity first,
   and how much headroom is left before it does?

   Three constraints are tested, in the order they bind in practice:
     1. plant blending capacity  (159,000 kl/year nameplate)
     2. depot throughput         (litres a depot can receive, pick and ship per week)
     3. depot storage            (litres it can physically hold)
   ========================================================================= */

USE LubeSupplyChain;
GO

/* ---------------------------------------------------------------------------
   6.1  Plant utilisation against nameplate
   ------------------------------------------------------------------------ */
SELECT
    YEAR(week_start_date)                                                 AS yr,
    COUNT(DISTINCT week_start_date)                                       AS weeks,
    CAST(SUM(actual_qty_l) / 1000.0 AS DECIMAL(12,0))                     AS produced_kl,
    CAST(SUM(planned_qty_l) / 1000.0 AS DECIMAL(12,0))                    AS planned_kl,
    CAST(100.0 * SUM(actual_qty_l)
         / (COUNT(DISTINCT week_start_date) * 159000.0 * 1000.0 / 52.0)
         AS DECIMAL(5,1))                                                 AS utilisation_pct_of_nameplate,
    CAST(100.0 * SUM(actual_qty_l) / NULLIF(SUM(planned_qty_l), 0)
         AS DECIMAL(5,1))                                                 AS plan_adherence_pct
FROM dbo.fact_production_batch
GROUP BY YEAR(week_start_date)
ORDER BY yr;

/* ---------------------------------------------------------------------------
   6.2  The peak week, not the average week
   Capacity is sized for peaks. An average utilisation of 80% with a peak of
   140% means the network is already breaking several weeks a year.
   ------------------------------------------------------------------------ */
WITH weekly AS (
    SELECT depot_id, week_start_date, SUM(dispatches_l) / 1000.0 AS kl
    FROM dbo.fact_depot_stock_weekly
    GROUP BY depot_id, week_start_date
)
SELECT
    d.depot_id, d.depot_name, d.region,
    d.throughput_capacity_kl_per_week                                        AS capacity_kl_per_week,
    CAST(AVG(w.kl) AS DECIMAL(10,1))                                         AS avg_week_kl,
    CAST(MAX(w.kl) AS DECIMAL(10,1))                                         AS peak_week_kl,
    CAST(100.0 * AVG(w.kl) / d.throughput_capacity_kl_per_week AS DECIMAL(5,1)) AS avg_utilisation_pct,
    CAST(100.0 * MAX(w.kl) / d.throughput_capacity_kl_per_week AS DECIMAL(5,1)) AS peak_utilisation_pct,
    SUM(CASE WHEN w.kl > d.throughput_capacity_kl_per_week THEN 1 ELSE 0 END) AS weeks_over_capacity,
    /* how much uniform growth this depot can absorb before the AVERAGE week
       breaches capacity - the headline headroom number */
    CAST(d.throughput_capacity_kl_per_week / NULLIF(AVG(w.kl), 0) AS DECIMAL(6,2)) AS breach_multiple
FROM weekly w
JOIN dbo.dim_depot d ON d.depot_id = w.depot_id
GROUP BY d.depot_id, d.depot_name, d.region, d.throughput_capacity_kl_per_week
ORDER BY breach_multiple ASC;

/* ---------------------------------------------------------------------------
   6.3  The stress test itself
   Scale every depot's average week by 1.00x, 1.25x, 1.50x and 2.00x and report
   what is still standing. This is the table that goes on the slide.
   ------------------------------------------------------------------------ */
WITH weekly AS (
    SELECT depot_id, week_start_date, SUM(dispatches_l) / 1000.0 AS kl
    FROM dbo.fact_depot_stock_weekly
    GROUP BY depot_id, week_start_date
),
avg_wk AS (
    SELECT depot_id, AVG(kl) AS avg_kl, MAX(kl) AS peak_kl
    FROM weekly GROUP BY depot_id
),
scenarios AS (
    SELECT 1.00 AS multiple UNION ALL SELECT 1.25 UNION ALL
    SELECT 1.50 UNION ALL SELECT 2.00
)
SELECT
    s.multiple                                                                AS demand_multiple,
    d.depot_name,
    CAST(a.avg_kl * s.multiple AS DECIMAL(10,1))                              AS stressed_avg_week_kl,
    d.throughput_capacity_kl_per_week                                         AS capacity_kl,
    CAST(100.0 * a.avg_kl * s.multiple / d.throughput_capacity_kl_per_week
         AS DECIMAL(6,1))                                                     AS utilisation_pct,
    CASE WHEN a.avg_kl * s.multiple > d.throughput_capacity_kl_per_week
         THEN 'BREACH' ELSE 'ok' END                                          AS status,
    CAST(CASE WHEN a.avg_kl * s.multiple > d.throughput_capacity_kl_per_week
              THEN a.avg_kl * s.multiple - d.throughput_capacity_kl_per_week
              ELSE 0 END AS DECIMAL(10,1))                                    AS shortfall_kl_per_week
FROM scenarios s
CROSS JOIN avg_wk a
JOIN dbo.dim_depot d ON d.depot_id = a.depot_id
ORDER BY s.multiple, utilisation_pct DESC;

/* ---------------------------------------------------------------------------
   6.4  Does the plant break before the depots do?
   ------------------------------------------------------------------------ */
WITH prod AS (
    SELECT SUM(actual_qty_l) / COUNT(DISTINCT week_start_date) AS avg_weekly_l
    FROM dbo.fact_production_batch
),
scenarios AS (
    SELECT 1.00 AS multiple UNION ALL SELECT 1.25 UNION ALL
    SELECT 1.50 UNION ALL SELECT 2.00
)
SELECT
    s.multiple                                                                    AS demand_multiple,
    CAST(p.avg_weekly_l * s.multiple / 1000.0 AS DECIMAL(12,1))                   AS required_kl_per_week,
    CAST(159000.0 / 52.0 AS DECIMAL(12,1))                                        AS plant_capacity_kl_per_week,
    CAST(100.0 * p.avg_weekly_l * s.multiple / (159000.0 * 1000.0 / 52.0)
         AS DECIMAL(6,1))                                                         AS plant_utilisation_pct,
    CASE WHEN p.avg_weekly_l * s.multiple > 159000.0 * 1000.0 / 52.0
         THEN 'BREACH' ELSE 'ok' END                                              AS status
FROM scenarios s CROSS JOIN prod p
ORDER BY s.multiple;

/* ---------------------------------------------------------------------------
   6.5  Storage headroom, on the most recent twelve months
   Throughput and storage are different constraints. A depot can have plenty of
   floor space and still be unable to move the volume, or the reverse.
   ------------------------------------------------------------------------ */
WITH per_week AS (
    SELECT depot_id, week_start_date, SUM(closing_stock_l) / 1000.0 AS stock_kl
    FROM dbo.fact_depot_stock_weekly
    WHERE week_start_date >= DATEADD(week, -52, (SELECT MAX(week_start_date) FROM dbo.fact_depot_stock_weekly))
    GROUP BY depot_id, week_start_date
)
SELECT
    d.depot_id, d.depot_name,
    d.storage_capacity_kl,
    CAST(AVG(w.stock_kl) AS DECIMAL(10,0))                                          AS avg_stock_kl,
    CAST(MAX(w.stock_kl) AS DECIMAL(10,0))                                          AS peak_stock_kl,
    CAST(100.0 * AVG(w.stock_kl) / d.storage_capacity_kl AS DECIMAL(5,1))           AS avg_storage_utilisation_pct,
    CAST(d.storage_capacity_kl / NULLIF(AVG(w.stock_kl), 0) AS DECIMAL(6,2))        AS storage_breach_multiple
FROM per_week w
JOIN dbo.dim_depot d ON d.depot_id = w.depot_id
GROUP BY d.depot_id, d.depot_name, d.storage_capacity_kl
ORDER BY avg_storage_utilisation_pct DESC;

/* ---------------------------------------------------------------------------
   6.6  Seasonality: when does the peak actually land?
   Useful for the recommendation - a capacity problem four weeks a year is a
   temporary labour and hired-transport problem, not a capex problem.
   ------------------------------------------------------------------------ */
SELECT
    MONTH(week_start_date)                                                    AS month_no,
    DATENAME(month, week_start_date)                                          AS month_name,
    CAST(SUM(dispatches_l) / COUNT(DISTINCT week_start_date) / 1000.0
         AS DECIMAL(10,1))                                                    AS avg_kl_per_week,
    CAST(100.0 * (SUM(dispatches_l) / COUNT(DISTINCT week_start_date))
         / (SELECT SUM(dispatches_l) / COUNT(DISTINCT week_start_date)
            FROM dbo.fact_depot_stock_weekly) AS DECIMAL(6,1))                AS index_vs_average
FROM dbo.fact_depot_stock_weekly
GROUP BY MONTH(week_start_date), DATENAME(month, week_start_date)
ORDER BY month_no;
GO
