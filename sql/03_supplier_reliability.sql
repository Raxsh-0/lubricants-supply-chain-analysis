/* ============================================================================
   03 - WHICH SUPPLIERS ARE ACTUALLY COSTING US?
   ----------------------------------------------------------------------------
   Business question: procurement ranks suppliers by price per kg. That is the
   wrong ranking. A cheap supplier that arrives late starves a blending batch,
   the batch runs short, a depot goes out of stock, and a distributor order
   cannot be filled. This script prices that chain.

   The join that makes it work:
       fact_inbound_po  ->  fact_production_batch.causing_po_id  ->  lost litres
   ========================================================================= */

USE LubeSupplyChain;
GO

/* ---------------------------------------------------------------------------
   3.1  Supplier scorecard: promise vs performance
   Two different failures live here. BIAS is being late on average - you can
   plan around that by adding days to the contract lead time. VARIANCE (lt_sd)
   is being unpredictable - you cannot plan around it at all, you can only hold
   safety stock against it. Variance is the expensive one.
   ------------------------------------------------------------------------ */
SELECT
    s.supplier_id, s.supplier_name, s.material_type, s.origin_hub,
    s.contract_lead_time_days,
    COUNT(*)                                                                       AS pos,
    CAST(AVG(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS DECIMAL(6,1)) AS actual_lead_time_days,
    CAST(STDEV(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS DECIMAL(6,1)) AS lead_time_sd,
    CAST(AVG(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2)))
         - s.contract_lead_time_days AS DECIMAL(6,1))                              AS bias_days,
    /* inbound OTIF: arrived by the promised date AND at least 97% of the quantity */
    CAST(100.0 * AVG(CASE WHEN p.actual_receipt_date <= p.promised_date
                           AND p.received_qty_kg >= p.ordered_qty_kg * 0.97
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,1))                  AS inbound_otif_pct,
    SUM(CASE WHEN DATEDIFF(day, p.promised_date, p.actual_receipt_date) > 0
             THEN DATEDIFF(day, p.promised_date, p.actual_receipt_date) ELSE 0 END) AS total_late_days,
    CAST(AVG(p.unit_price_inr_per_kg) AS DECIMAL(10,1))                            AS avg_price_per_kg,
    CAST(SUM(p.po_value_inr) / 10000000.0 AS DECIMAL(10,2))                        AS spend_cr
FROM dbo.fact_inbound_po p
JOIN dbo.dim_supplier s ON s.supplier_id = p.supplier_id
GROUP BY s.supplier_id, s.supplier_name, s.material_type, s.origin_hub, s.contract_lead_time_days
ORDER BY inbound_otif_pct ASC;

/* ---------------------------------------------------------------------------
   3.2  Imported vs domestic
   Before blaming individual suppliers, check whether the pattern is structural.
   ------------------------------------------------------------------------ */
SELECT
    CASE WHEN s.origin_hub LIKE 'Import%' THEN 'Imported' ELSE 'Domestic' END      AS sourcing,
    COUNT(*)                                                                       AS pos,
    CAST(AVG(CAST(s.contract_lead_time_days AS DECIMAL(9,2))) AS DECIMAL(6,1))     AS avg_contract_lt,
    CAST(STDEV(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS DECIMAL(6,1)) AS lead_time_sd,
    CAST(100.0 * AVG(CASE WHEN p.actual_receipt_date <= p.promised_date
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,1))                  AS on_time_pct,
    CAST(100.0 * AVG(CASE WHEN p.received_qty_kg < p.ordered_qty_kg * 0.97
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,1))                  AS short_shipped_pct
FROM dbo.fact_inbound_po p
JOIN dbo.dim_supplier s ON s.supplier_id = p.supplier_id
GROUP BY CASE WHEN s.origin_hub LIKE 'Import%' THEN 'Imported' ELSE 'Domestic' END;

/* ---------------------------------------------------------------------------
   3.3  What stopped production, and how much volume did it cost?
   ------------------------------------------------------------------------ */
SELECT
    delay_reason,
    COUNT(*)                                                                    AS batches,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,2))              AS pct_of_batches,
    CAST(AVG(CAST(delay_days AS DECIMAL(9,2))) AS DECIMAL(6,2))                 AS avg_delay_days,
    CAST(SUM(planned_qty_l - actual_qty_l) / 1000.0 AS DECIMAL(12,0))           AS shortfall_kl,
    CAST(100.0 * SUM(planned_qty_l - actual_qty_l)
         / NULLIF(SUM(SUM(planned_qty_l - actual_qty_l)) OVER (), 0)
         AS DECIMAL(5,1))                                                       AS pct_of_shortfall
FROM dbo.fact_production_batch
GROUP BY delay_reason
ORDER BY shortfall_kl DESC;

/* ---------------------------------------------------------------------------
   3.4  THE KEY QUERY - trace lost production back to the supplier that caused it
   A three-table join that converts a procurement decision into a service number.
   ------------------------------------------------------------------------ */
SELECT
    s.supplier_id, s.supplier_name, s.material_type, s.origin_hub,
    COUNT(*)                                                                    AS batches_starved,
    CAST(SUM(b.planned_qty_l - b.actual_qty_l) / 1000.0 AS DECIMAL(12,1))       AS production_lost_kl,
    CAST(AVG(CAST(b.delay_days AS DECIMAL(9,2))) AS DECIMAL(6,2))               AS avg_batch_delay_days,
    /* value the lost production at the gross margin it would have earned */
    CAST(SUM((b.planned_qty_l - b.actual_qty_l)
             * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 10000000.0
         AS DECIMAL(12,2))                                                      AS margin_at_risk_cr
FROM dbo.fact_production_batch b
JOIN dbo.fact_inbound_po p ON p.po_id       = b.causing_po_id
JOIN dbo.dim_supplier    s ON s.supplier_id = p.supplier_id
JOIN dbo.dim_sku         k ON k.sku_id      = b.sku_id
WHERE b.delay_reason = 'RAW_MATERIAL_SHORT'
GROUP BY s.supplier_id, s.supplier_name, s.material_type, s.origin_hub
ORDER BY production_lost_kl DESC;

/* ---------------------------------------------------------------------------
   3.5  THE FINDING - cheapest on paper, most expensive in practice
   Within each material category, rank suppliers two ways: by price per kg, and
   by the production they cost us. If the same supplier is rank 1 on both, the
   procurement scorecard is measuring the wrong thing.
   ------------------------------------------------------------------------ */
WITH price AS (
    SELECT s.supplier_id, s.supplier_name, s.material_type,
           CAST(AVG(p.unit_price_inr_per_kg) AS DECIMAL(10,1)) AS price_per_kg,
           SUM(p.received_qty_kg)                              AS kg_received,
           SUM(p.po_value_inr)                                 AS spend_inr
    FROM dbo.fact_inbound_po p
    JOIN dbo.dim_supplier s ON s.supplier_id = p.supplier_id
    GROUP BY s.supplier_id, s.supplier_name, s.material_type
),
damage AS (
    SELECT p.supplier_id,
           SUM(b.planned_qty_l - b.actual_qty_l) AS production_lost_l,
           SUM((b.planned_qty_l - b.actual_qty_l)
               * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) AS margin_lost_inr
    FROM dbo.fact_production_batch b
    JOIN dbo.fact_inbound_po p ON p.po_id  = b.causing_po_id
    JOIN dbo.dim_sku         k ON k.sku_id = b.sku_id
    WHERE b.delay_reason = 'RAW_MATERIAL_SHORT'
    GROUP BY p.supplier_id
)
SELECT
    pr.material_type, pr.supplier_id, pr.supplier_name,
    pr.price_per_kg,
    RANK() OVER (PARTITION BY pr.material_type ORDER BY pr.price_per_kg ASC)                     AS rank_cheapest,
    CAST(COALESCE(dm.production_lost_l, 0) / 1000.0 AS DECIMAL(12,1))                            AS production_lost_kl,
    RANK() OVER (PARTITION BY pr.material_type ORDER BY COALESCE(dm.production_lost_l,0) DESC)   AS rank_most_damage,
    CAST(pr.spend_inr / 10000000.0 AS DECIMAL(12,2))                                             AS spend_cr,
    CAST(COALESCE(dm.margin_lost_inr,0) / 10000000.0 AS DECIMAL(12,2))                           AS margin_lost_cr,
    /* the number that reframes the decision: effective cost per kg once the
       margin lost downstream is added back to the purchase price */
    CAST((pr.spend_inr + COALESCE(dm.margin_lost_inr,0)) / NULLIF(pr.kg_received,0)
         AS DECIMAL(10,1))                                                                       AS true_cost_per_kg
FROM price pr
LEFT JOIN damage dm ON dm.supplier_id = pr.supplier_id
WHERE pr.material_type IN ('BASE_OIL_G2','BASE_OIL_G3','ADDITIVE')
ORDER BY pr.material_type, pr.price_per_kg;

/* ---------------------------------------------------------------------------
   3.6  How much safety stock does a supplier's UNRELIABILITY force us to hold?
   Standard formula:  safety stock = Z * demand_per_day * SD(lead time)
   Z = 1.65 for a 95% service level. This converts erratic delivery into a
   rupee number, which is the language a procurement review responds to.

   SCOPE, and say this if asked: base oil suppliers only. Additive, packaging,
   thickener and solvent suppliers are excluded because consumption per litre
   of finished product varies by formulation and is not in this dataset. The
   base oils are ~75% of material spend, so the ranking is representative, but
   it is not the whole book.
   ------------------------------------------------------------------------ */
WITH lt AS (
    SELECT p.supplier_id, s.supplier_name, s.material_type,
           STDEV(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS lt_sd
    FROM dbo.fact_inbound_po p
    JOIN dbo.dim_supplier s ON s.supplier_id = p.supplier_id
    GROUP BY p.supplier_id, s.supplier_name, s.material_type
),
usage AS (   /* daily litres of finished product using each material group */
    SELECT CASE k.base_oil_group WHEN 'I' THEN 'BASE_OIL_G1'
                                 WHEN 'II' THEN 'BASE_OIL_G2'
                                 ELSE 'BASE_OIL_G3' END AS material_type,
           SUM(b.actual_qty_l) / 1095.0                 AS litres_per_day   -- 3 years
    FROM dbo.fact_production_batch b
    JOIN dbo.dim_sku k ON k.sku_id = b.sku_id
    GROUP BY CASE k.base_oil_group WHEN 'I' THEN 'BASE_OIL_G1'
                                   WHEN 'II' THEN 'BASE_OIL_G2'
                                   ELSE 'BASE_OIL_G3' END
)
SELECT
    lt.supplier_id, lt.supplier_name, lt.material_type,
    CAST(lt.lt_sd AS DECIMAL(6,1))                                        AS lead_time_sd_days,
    CAST(u.litres_per_day AS DECIMAL(12,0))                               AS material_litres_per_day,
    CAST(1.65 * u.litres_per_day * lt.lt_sd / 1000.0 AS DECIMAL(12,1))    AS safety_stock_kl_at_95pct,
    CAST(1.65 * u.litres_per_day * lt.lt_sd * 0.87 * 100.0 / 10000000.0
         AS DECIMAL(12,2))                                                AS safety_stock_value_cr
FROM lt
JOIN usage u ON u.material_type = lt.material_type
ORDER BY safety_stock_value_cr DESC;
GO
