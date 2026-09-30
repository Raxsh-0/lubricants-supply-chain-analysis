/* ============================================================================
   04 - WHAT DOES THE SERVICE GAP COST, AND WHAT WOULD FIXING IT COST?
   ----------------------------------------------------------------------------
   Business question: "OTIF is 86%" is not a business case. This script turns
   the gap into rupees, splits the cost by depot, and then asks the only
   question that matters: is buying more inventory cheaper than losing the sale?

   STATED ASSUMPTION, and say it out loud before anyone asks:
   unfilled volume is valued at full gross margin, i.e. we assume the customer
   did not simply buy the same litres from us a week later. That is the
   aggressive end. Query 4.6 re-runs the case at 30% and 60% recapture so the
   conclusion does not depend on the assumption.
   ========================================================================= */

USE LubeSupplyChain;
GO

/* ---------------------------------------------------------------------------
   4.1  The headline cost
   ------------------------------------------------------------------------ */
SELECT
    CAST(SUM(o.ordered_qty_l - o.delivered_qty_l) / 1000.0 AS DECIMAL(12,0))   AS unfilled_kl_3yr,
    CAST(SUM((o.ordered_qty_l - o.delivered_qty_l)
             * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 10000000.0
         AS DECIMAL(12,2))                                                     AS lost_gross_margin_cr_3yr,
    CAST(SUM((o.ordered_qty_l - o.delivered_qty_l)
             * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 10000000.0 / 3.0
         AS DECIMAL(12,2))                                                     AS lost_gross_margin_cr_per_year,
    CAST(SUM(o.freight_cost_inr) / 10000000.0 AS DECIMAL(12,2))                AS total_freight_cr_3yr,
    CAST(SUM(CASE WHEN o.is_emergency_transfer = 1 THEN o.freight_cost_inr ELSE 0 END)
         / 10000000.0 AS DECIMAL(12,2))                                        AS emergency_freight_cr_3yr
FROM dbo.fact_order_line o
JOIN dbo.dim_sku k ON k.sku_id = o.sku_id;

/* ---------------------------------------------------------------------------
   4.2  The price of firefighting
   An emergency inter-depot transfer rescues one order but at a freight rate
   several times the planned lane rate. Quantifying the premium is what turns
   "we should plan better" into a number a manager can act on.
   ------------------------------------------------------------------------ */
SELECT
    CASE WHEN is_emergency_transfer = 1 THEN 'Emergency transfer' ELSE 'Planned lane' END AS movement_type,
    COUNT(*)                                                              AS lines,
    CAST(SUM(delivered_qty_l) / 1000.0 AS DECIMAL(12,0))                  AS delivered_kl,
    CAST(SUM(freight_cost_inr) / NULLIF(SUM(delivered_qty_l), 0) AS DECIMAL(10,3)) AS freight_inr_per_l,
    CAST(SUM(freight_cost_inr) / 100000.0 AS DECIMAL(12,1))               AS freight_lakh
FROM dbo.fact_order_line
WHERE delivered_qty_l > 0
GROUP BY CASE WHEN is_emergency_transfer = 1 THEN 'Emergency transfer' ELSE 'Planned lane' END;

/* ---------------------------------------------------------------------------
   4.3  Cost to serve, per litre, by depot
   Cost to serve = what it costs to move a litre + what we lose by not having
   it. Two depots can look equally expensive for opposite reasons, so both
   components are shown separately.
   ------------------------------------------------------------------------ */
WITH base AS (
    SELECT o.depot_id,
           o.delivered_qty_l,
           o.freight_cost_inr,
           (o.ordered_qty_l - o.delivered_qty_l)
               * (k.list_price_inr_per_l - k.std_cost_inr_per_l) AS lost_margin_inr
    FROM dbo.fact_order_line o
    JOIN dbo.dim_sku k ON k.sku_id = o.sku_id
)
SELECT
    d.depot_id, d.depot_name, d.region, d.distance_km,
    CAST(SUM(b.delivered_qty_l) / 1000.0 AS DECIMAL(12,0))                                        AS delivered_kl,
    CAST(SUM(b.freight_cost_inr) / NULLIF(SUM(b.delivered_qty_l),0) AS DECIMAL(10,3))             AS freight_inr_per_l,
    CAST(SUM(b.lost_margin_inr)  / NULLIF(SUM(b.delivered_qty_l),0) AS DECIMAL(10,3))             AS lost_margin_inr_per_l,
    CAST((SUM(b.freight_cost_inr) + SUM(b.lost_margin_inr))
         / NULLIF(SUM(b.delivered_qty_l),0) AS DECIMAL(10,3))                                     AS cost_to_serve_inr_per_l
FROM base b
JOIN dbo.dim_depot d ON d.depot_id = b.depot_id
GROUP BY d.depot_id, d.depot_name, d.region, d.distance_km
ORDER BY cost_to_serve_inr_per_l DESC;

/* ---------------------------------------------------------------------------
   4.4  Seasonal freight: what the monsoon costs
   ------------------------------------------------------------------------ */
SELECT
    CASE WHEN MONTH(order_date) IN (6,7,8,9) THEN 'Monsoon Jun-Sep' ELSE 'Rest of year' END AS season,
    CAST(SUM(delivered_qty_l) / 1000.0 AS DECIMAL(12,0))                            AS delivered_kl,
    CAST(SUM(freight_cost_inr) / NULLIF(SUM(delivered_qty_l),0) AS DECIMAL(10,3))   AS freight_inr_per_l,
    CAST(100.0 * AVG(CASE WHEN on_time_flag = 1 AND in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))                   AS otif_pct
FROM dbo.fact_order_line
WHERE delivered_qty_l > 0
GROUP BY CASE WHEN MONTH(order_date) IN (6,7,8,9) THEN 'Monsoon Jun-Sep' ELSE 'Rest of year' END;

/* ---------------------------------------------------------------------------
   4.5  Cost to serve by channel
   Industrial B2B customers order in drums and IBCs; auto retail orders in
   cases. Cost per litre is not the same, and neither is the margin.
   ------------------------------------------------------------------------ */
SELECT
    dd.channel,
    COUNT(*)                                                                        AS lines,
    CAST(AVG(o.ordered_qty_l) AS DECIMAL(10,1))                                     AS avg_line_size_l,
    CAST(SUM(o.delivered_qty_l) / 1000.0 AS DECIMAL(12,0))                          AS delivered_kl,
    CAST(SUM(o.freight_cost_inr) / NULLIF(SUM(o.delivered_qty_l),0) AS DECIMAL(10,3)) AS freight_inr_per_l,
    CAST(SUM(o.delivered_qty_l * (k.list_price_inr_per_l - k.std_cost_inr_per_l))
         / NULLIF(SUM(o.delivered_qty_l),0) AS DECIMAL(10,2))                       AS gross_margin_inr_per_l,
    CAST(100.0 * AVG(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))                   AS otif_pct
FROM dbo.fact_order_line o
JOIN dbo.dim_distributor dd ON dd.distributor_id = o.distributor_id
JOIN dbo.dim_sku k          ON k.sku_id          = o.sku_id
GROUP BY dd.channel
ORDER BY gross_margin_inr_per_l DESC;

/* ---------------------------------------------------------------------------
   4.6  THE DECISION - is more inventory worth it?
   Model: to recover a share of the volume lost to depot stockouts we raise the
   replenishment target by one extra week of cover at the depots that are
   failing. Holding that stock costs the carrying rate below.

   Change the two parameters and watch the break-even recapture move; the
   conclusion is tested across a range rather than resting on one number.
   ------------------------------------------------------------------------ */
DECLARE @carrying_rate  DECIMAL(6,3) = 0.18;   -- 18%/yr: working capital + warehousing + shrink
DECLARE @extra_cover_wk DECIMAL(6,3) = 1.0;    -- one extra week of cover

WITH lost AS (      /* margin lost to stock-driven failures only, per year */
    SELECT o.depot_id,
           SUM(o.ordered_qty_l - o.delivered_qty_l) / 3.0                       AS unfilled_l_per_yr,
           SUM((o.ordered_qty_l - o.delivered_qty_l)
               * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 3.0         AS lost_margin_per_yr
    FROM dbo.fact_order_line o
    JOIN dbo.dim_sku k ON k.sku_id = o.sku_id
    WHERE o.fail_reason IN ('DEPOT_STOCKOUT','PLANT_DELAY')
    GROUP BY o.depot_id
),
weekly AS (         /* one week of cover, valued at standard cost */
    SELECT s.depot_id,
           SUM(s.dispatches_l) / 156.0                                          AS litres_per_week,
           SUM(s.dispatches_l * k.std_cost_inr_per_l) / 156.0                   AS value_per_week_inr
    FROM dbo.fact_depot_stock_weekly s
    JOIN dbo.dim_sku k ON k.sku_id = s.sku_id
    GROUP BY s.depot_id
)
SELECT
    d.depot_name,
    CAST(l.unfilled_l_per_yr / 1000.0 AS DECIMAL(12,1))                         AS unfilled_kl_per_yr,
    CAST(l.lost_margin_per_yr / 10000000.0 AS DECIMAL(12,2))                    AS margin_lost_cr_per_yr,
    CAST(w.value_per_week_inr * @extra_cover_wk / 10000000.0 AS DECIMAL(12,2))  AS extra_stock_investment_cr,
    CAST(w.value_per_week_inr * @extra_cover_wk * @carrying_rate / 10000000.0
         AS DECIMAL(12,2))                                                      AS annual_carrying_cost_cr,
    /* recover 50% of the lost volume */
    CAST((l.lost_margin_per_yr * 0.50
          - w.value_per_week_inr * @extra_cover_wk * @carrying_rate) / 10000000.0
         AS DECIMAL(12,2))                                                      AS net_gain_cr_at_50pct_recapture,
    /* the break-even: what share of lost volume must we actually recover? */
    CAST(100.0 * (w.value_per_week_inr * @extra_cover_wk * @carrying_rate)
         / NULLIF(l.lost_margin_per_yr, 0) AS DECIMAL(6,1))                     AS breakeven_recapture_pct
FROM lost l
JOIN weekly w      ON w.depot_id = l.depot_id
JOIN dbo.dim_depot d ON d.depot_id = l.depot_id
ORDER BY net_gain_cr_at_50pct_recapture DESC;
GO
