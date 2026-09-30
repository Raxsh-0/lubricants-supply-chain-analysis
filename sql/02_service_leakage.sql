/* ============================================================================
   02 - WHERE IS SERVICE LEAKING?
   ----------------------------------------------------------------------------
   Business question: we promise distributors delivery on time and in full.
   We miss on roughly one line in seven. Which stage of the chain is losing it,
   and is the problem the same at every depot?

   OTIF is the standard supply chain service metric:
       OTIF = share of order lines delivered ON TIME *and* IN FULL.
   It is deliberately harsh - a line that arrives complete but two days late
   scores zero, and so does a line that arrives on the promised day but short.
   Published benchmarks for industrial goods distribution: 85-92% is "good",
   92-95% is "excellent".
   ========================================================================= */

USE LubeSupplyChain;
GO

/* ---------------------------------------------------------------------------
   2.1  The headline: how are we doing, and which half of OTIF is the problem?
   ------------------------------------------------------------------------ */
SELECT
    COUNT(*)                                                        AS order_lines,
    CAST(100.0 * AVG(CAST(on_time_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS on_time_pct,
    CAST(100.0 * AVG(CAST(in_full_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS in_full_pct,
    CAST(100.0 * AVG(CASE WHEN on_time_flag = 1 AND in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))   AS otif_pct,
    CAST(SUM(ordered_qty_l)   / 1000000.0 AS DECIMAL(10,1))         AS ordered_million_l,
    CAST(SUM(delivered_qty_l) / 1000000.0 AS DECIMAL(10,1))         AS delivered_million_l
FROM dbo.fact_order_line;

/* ---------------------------------------------------------------------------
   2.2  Failure mix: count of lines vs volume lost
   Two different questions. A credit hold blocks a whole line, so it is rare by
   count but heavy by volume. Read both columns before deciding what to fix.
   ------------------------------------------------------------------------ */
SELECT
    fail_reason,
    COUNT(*)                                                             AS lines,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))       AS pct_of_lines,
    CAST(SUM(ordered_qty_l - delivered_qty_l) / 1000.0 AS DECIMAL(12,0)) AS lost_kl,
    CAST(100.0 * SUM(ordered_qty_l - delivered_qty_l)
         / NULLIF(SUM(SUM(ordered_qty_l - delivered_qty_l)) OVER (), 0)
         AS DECIMAL(5,1))                                                AS pct_of_lost_volume
FROM dbo.fact_order_line
GROUP BY fail_reason
ORDER BY lost_kl DESC;

/* ---------------------------------------------------------------------------
   2.3  OTIF by depot, against distance from the plant
   The question behind this: is bad service a distance problem or a management
   problem? Sort by transit days and see whether OTIF falls monotonically.
   ------------------------------------------------------------------------ */
SELECT
    d.depot_id, d.depot_name, d.region,
    d.distance_km, d.std_transit_days,
    COUNT(*)                                                              AS lines,
    CAST(100.0 * AVG(CAST(o.on_time_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS on_time_pct,
    CAST(100.0 * AVG(CAST(o.in_full_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS in_full_pct,
    CAST(100.0 * AVG(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))         AS otif_pct
FROM dbo.fact_order_line o
JOIN dbo.dim_depot d ON d.depot_id = o.depot_id
GROUP BY d.depot_id, d.depot_name, d.region, d.distance_km, d.std_transit_days
ORDER BY otif_pct;

/* ---------------------------------------------------------------------------
   2.4  Failure mix WITHIN each depot
   The same headline OTIF can hide completely different problems. A depot that
   fails on transport needs a carrier conversation; one that fails on stock
   needs a replenishment fix. Never recommend one remedy for both.
   ------------------------------------------------------------------------ */
SELECT
    d.depot_name,
    CAST(100.0 * AVG(CASE WHEN o.fail_reason = 'DEPOT_STOCKOUT'  THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2)) AS pct_depot_stockout,
    CAST(100.0 * AVG(CASE WHEN o.fail_reason = 'PLANT_DELAY'     THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2)) AS pct_plant_delay,
    CAST(100.0 * AVG(CASE WHEN o.fail_reason = 'TRANSPORT_DELAY' THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2)) AS pct_transport_delay,
    CAST(100.0 * AVG(CASE WHEN o.fail_reason = 'CREDIT_HOLD'     THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2)) AS pct_credit_hold
FROM dbo.fact_order_line o
JOIN dbo.dim_depot d ON d.depot_id = o.depot_id
GROUP BY d.depot_name
ORDER BY pct_depot_stockout DESC;

/* ---------------------------------------------------------------------------
   2.5  Monthly OTIF trend, with the monsoon marked
   June to September is the Indian monsoon: road transit slows and freight
   rates harden. This query answers "is our service problem seasonal, and
   therefore predictable?"
   ------------------------------------------------------------------------ */
SELECT
    DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)                 AS month_start,
    CASE WHEN MONTH(order_date) IN (6,7,8,9) THEN 'Monsoon' ELSE 'Normal' END AS season,
    COUNT(*)                                                              AS lines,
    CAST(100.0 * AVG(CASE WHEN on_time_flag = 1 AND in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))         AS otif_pct,
    CAST(100.0 * AVG(CAST(on_time_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS on_time_pct,
    CAST(100.0 * AVG(CAST(in_full_flag AS DECIMAL(5,2))) AS DECIMAL(5,2)) AS in_full_pct
FROM dbo.fact_order_line
GROUP BY DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1),
         CASE WHEN MONTH(order_date) IN (6,7,8,9) THEN 'Monsoon' ELSE 'Normal' END
ORDER BY month_start;

/* ---------------------------------------------------------------------------
   2.6  How late is late? Distribution of delay, not just the average.
   An average of 3 days can mean "everything is 3 days late" or "most things
   are on time and a few are catastrophic". Those need different fixes.
   ------------------------------------------------------------------------ */
SELECT
    d.depot_name,
    COUNT(*)                                                                AS delivered_lines,
    CAST(AVG(CAST(DATEDIFF(day, o.promised_delivery_date, o.actual_delivery_date) AS DECIMAL(9,2))) AS DECIMAL(6,2)) AS avg_days_vs_promise,
    MAX(DATEDIFF(day, o.promised_delivery_date, o.actual_delivery_date))    AS worst_days_late,
    CAST(100.0 * AVG(CASE WHEN DATEDIFF(day, o.promised_delivery_date, o.actual_delivery_date) > 3
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))           AS pct_more_than_3_days_late
FROM dbo.fact_order_line o
JOIN dbo.dim_depot d ON d.depot_id = o.depot_id
WHERE o.actual_delivery_date IS NOT NULL          -- exclude lines that never shipped
GROUP BY d.depot_name
ORDER BY pct_more_than_3_days_late DESC;

/* ---------------------------------------------------------------------------
   2.7  Which distributors feel the pain?
   Service failure is not spread evenly. This is the list a sales manager
   actually wants: our biggest customers, ranked by how badly we serve them.
   ------------------------------------------------------------------------ */
SELECT TOP 20
    dd.distributor_id, dd.distributor_name, dd.city, dd.channel, dd.tier,
    COUNT(*)                                                        AS lines,
    CAST(SUM(o.delivered_qty_l) / 1000.0 AS DECIMAL(12,1))          AS delivered_kl,
    CAST(100.0 * AVG(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))   AS otif_pct
FROM dbo.fact_order_line o
JOIN dbo.dim_distributor dd ON dd.distributor_id = o.distributor_id
GROUP BY dd.distributor_id, dd.distributor_name, dd.city, dd.channel, dd.tier
HAVING SUM(o.delivered_qty_l) > 500000            -- only distributors that matter
ORDER BY otif_pct ASC;
GO
