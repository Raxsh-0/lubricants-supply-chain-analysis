/* ============================================================================
   07 - VIEWS FOR POWER BI
   ----------------------------------------------------------------------------
   Power BI connects to these, not to the raw tables. Two reasons:

   1. The business logic - what counts as OTIF, how ABC classes are cut, how
      lost margin is valued - lives in ONE place. If it changes, every visual
      changes with it. Definitions duplicated in DAX drift apart.
   2. The report imports a star schema (one fact plus small dimensions), not
      one giant flat table, so the model stays small and the filters stay fast.

   Import all seven views. Set the relationships in Model view:
       vw_pbi_order_line[depot_id]       -> dim_depot[depot_id]
       vw_pbi_order_line[sku_id]         -> dim_sku[sku_id]
       vw_pbi_order_line[distributor_id] -> dim_distributor[distributor_id]
       vw_pbi_order_line[order_date]     -> vw_pbi_date[date_key]
       vw_pbi_order_line[sku_id]         -> vw_pbi_sku_abc[sku_id]   (or merge into dim_sku)
   All are one-to-many, single direction, dimension filtering fact.
   ========================================================================= */

USE LubeSupplyChain;
GO

/* RUN ORDER: 05_inventory_allocation.sql must have been run at least once,
   because vw_pbi_sku below depends on the vw_sku_abc view it creates. If you
   get "Invalid object name 'dbo.vw_sku_abc'", that is the reason. */

/* ---------------------------------------------------------------------------
   7.1  Date dimension
   Every Power BI model needs one. Without it, time intelligence (year to date,
   same period last year) does not work reliably.
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_date') IS NOT NULL DROP VIEW dbo.vw_pbi_date;
GO
CREATE VIEW dbo.vw_pbi_date AS
WITH n AS (
    SELECT TOP (1200) ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
    FROM sys.all_columns a CROSS JOIN sys.all_columns b   -- plenty of rows on any instance
),
d AS (
    SELECT DATEADD(day, i, CAST('2023-09-04' AS DATE)) AS date_key FROM n
)
SELECT
    date_key,
    YEAR(date_key)                                          AS year_no,
    MONTH(date_key)                                         AS month_no,
    DATENAME(month, date_key)                               AS month_name,
    LEFT(DATENAME(month, date_key), 3) + ' '
        + RIGHT(CAST(YEAR(date_key) AS VARCHAR(4)), 2)      AS month_label,
    DATEFROMPARTS(YEAR(date_key), MONTH(date_key), 1)       AS month_start,
    DATEPART(quarter, date_key)                             AS quarter_no,
    'FY' + RIGHT(CAST(CASE WHEN MONTH(date_key) >= 4 THEN YEAR(date_key) + 1
                           ELSE YEAR(date_key) END AS VARCHAR(4)), 2)  AS indian_fiscal_year,
    CASE WHEN MONTH(date_key) IN (6,7,8,9) THEN 'Monsoon'
         WHEN MONTH(date_key) IN (10,11)   THEN 'Festive'
         ELSE 'Normal' END                                  AS season
FROM d
WHERE date_key <= '2026-09-30';
GO

/* ---------------------------------------------------------------------------
   7.2  The fact table for the report
   One row per order line, already carrying the derived measures that are
   awkward or slow to compute in DAX.
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_order_line') IS NOT NULL DROP VIEW dbo.vw_pbi_order_line;
GO
CREATE VIEW dbo.vw_pbi_order_line AS
SELECT
    o.order_line_id,
    o.order_date,
    o.distributor_id,
    o.depot_id,
    o.sku_id,
    o.ordered_qty_l,
    o.delivered_qty_l,
    o.ordered_qty_l - o.delivered_qty_l                                  AS unfilled_qty_l,
    o.on_time_flag,
    o.in_full_flag,
    CAST(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
              THEN 1 ELSE 0 END AS TINYINT)                              AS otif_flag,
    o.fail_reason,
    /* a friendlier label for the failure axis on a chart */
    CASE o.fail_reason
         WHEN 'NONE'            THEN 'Delivered as promised'
         WHEN 'DEPOT_STOCKOUT'  THEN 'Depot out of stock'
         WHEN 'PLANT_DELAY'     THEN 'Plant production delay'
         WHEN 'TRANSPORT_DELAY' THEN 'Transport delay'
         WHEN 'CREDIT_HOLD'     THEN 'Commercial / credit hold'
    END                                                                  AS fail_reason_label,
    o.is_emergency_transfer,
    o.freight_cost_inr,
    CASE WHEN o.actual_delivery_date IS NULL THEN NULL
         ELSE DATEDIFF(day, o.promised_delivery_date, o.actual_delivery_date)
    END                                                                  AS days_vs_promise,
    o.delivered_qty_l * (k.list_price_inr_per_l - k.std_cost_inr_per_l)  AS gross_margin_inr,
    (o.ordered_qty_l - o.delivered_qty_l)
        * (k.list_price_inr_per_l - k.std_cost_inr_per_l)                AS lost_margin_inr,
    o.delivered_qty_l * k.list_price_inr_per_l                           AS revenue_inr
FROM dbo.fact_order_line o
JOIN dbo.dim_sku k ON k.sku_id = o.sku_id;
GO

/* ---------------------------------------------------------------------------
   7.3  SKU dimension with the ABC class already attached
   Import this instead of dim_sku so the class is a slicer, not a calculation.
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_sku') IS NOT NULL DROP VIEW dbo.vw_pbi_sku;
GO
CREATE VIEW dbo.vw_pbi_sku AS
SELECT
    k.sku_id, k.sku_name, k.segment_code, k.segment_name, k.tier_code,
    k.base_oil_group, k.pack_size_l, k.list_price_inr_per_l, k.std_cost_inr_per_l,
    k.list_price_inr_per_l - k.std_cost_inr_per_l                         AS gross_margin_inr_per_l,
    CAST(100.0 * (k.list_price_inr_per_l - k.std_cost_inr_per_l)
         / NULLIF(k.list_price_inr_per_l, 0) AS DECIMAL(5,1))             AS gross_margin_pct,
    k.shelf_life_months,
    a.abc_class,
    a.volume_rank,
    CASE WHEN k.pack_size_l >= 200 THEN 'Bulk (drum / IBC)'
         WHEN k.pack_size_l >= 18  THEN 'Medium (pail / keg)'
         ELSE 'Small pack' END                                            AS pack_group
FROM dbo.dim_sku k
LEFT JOIN dbo.vw_sku_abc a ON a.sku_id = k.sku_id;
GO

/* ---------------------------------------------------------------------------
   7.4  Supplier scorecard - one row per supplier, page 2 of the report
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_supplier_scorecard') IS NOT NULL DROP VIEW dbo.vw_pbi_supplier_scorecard;
GO
CREATE VIEW dbo.vw_pbi_supplier_scorecard AS
WITH po AS (
    SELECT p.supplier_id,
           COUNT(*)                                                                     AS pos,
           AVG(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS actual_lt,
           STDEV(CAST(DATEDIFF(day, p.order_date, p.actual_receipt_date) AS DECIMAL(9,2))) AS lt_sd,
           100.0 * AVG(CASE WHEN p.actual_receipt_date <= p.promised_date
                             AND p.received_qty_kg >= p.ordered_qty_kg * 0.97
                            THEN 1.0 ELSE 0.0 END)                                      AS inbound_otif_pct,
           SUM(p.po_value_inr)                                                          AS spend_inr,
           SUM(p.received_qty_kg)                                                       AS kg_received,
           AVG(p.unit_price_inr_per_kg)                                                 AS price_per_kg
    FROM dbo.fact_inbound_po p
    GROUP BY p.supplier_id
),
dmg AS (
    SELECT p.supplier_id,
           SUM(b.planned_qty_l - b.actual_qty_l)                                        AS production_lost_l,
           SUM((b.planned_qty_l - b.actual_qty_l)
               * (k.list_price_inr_per_l - k.std_cost_inr_per_l))                       AS margin_lost_inr,
           COUNT(*)                                                                     AS batches_starved
    FROM dbo.fact_production_batch b
    JOIN dbo.fact_inbound_po p ON p.po_id  = b.causing_po_id
    JOIN dbo.dim_sku         k ON k.sku_id = b.sku_id
    WHERE b.delay_reason = 'RAW_MATERIAL_SHORT'
    GROUP BY p.supplier_id
)
SELECT
    s.supplier_id, s.supplier_name, s.material_type, s.origin_hub,
    CASE WHEN s.origin_hub LIKE 'Import%' THEN 'Imported' ELSE 'Domestic' END  AS sourcing,
    s.contract_lead_time_days,
    po.pos                                                        AS purchase_orders,
    CAST(po.actual_lt AS DECIMAL(8,1))                            AS actual_lead_time_days,
    CAST(po.lt_sd     AS DECIMAL(8,1))                            AS lead_time_sd_days,
    CAST(po.actual_lt - s.contract_lead_time_days AS DECIMAL(8,1)) AS bias_days,
    CAST(po.inbound_otif_pct AS DECIMAL(5,1))                     AS inbound_otif_pct,
    CAST(po.price_per_kg AS DECIMAL(10,1))                        AS price_per_kg,
    CAST(po.spend_inr / 10000000.0 AS DECIMAL(12,2))              AS spend_cr,
    CAST(COALESCE(dmg.production_lost_l,0) / 1000.0 AS DECIMAL(12,1)) AS production_lost_kl,
    CAST(COALESCE(dmg.margin_lost_inr,0) / 10000000.0 AS DECIMAL(12,2)) AS margin_lost_cr,
    COALESCE(dmg.batches_starved, 0)                              AS batches_starved,
    CAST((po.spend_inr + COALESCE(dmg.margin_lost_inr,0))
         / NULLIF(po.kg_received,0) AS DECIMAL(10,1))             AS true_cost_per_kg,
    /* the quadrant label that drives the scatter plot on page 2 */
    CASE WHEN po.inbound_otif_pct >= 70 AND COALESCE(dmg.margin_lost_inr,0) <  50000000 THEN 'Keep'
         WHEN po.inbound_otif_pct >= 70                                                  THEN 'Watch'
         WHEN COALESCE(dmg.margin_lost_inr,0) >= 50000000                                THEN 'Fix or replace'
         ELSE 'Monitor' END                                       AS action_quadrant
FROM dbo.dim_supplier s
JOIN po ON po.supplier_id = s.supplier_id
LEFT JOIN dmg ON dmg.supplier_id = s.supplier_id;
GO

/* ---------------------------------------------------------------------------
   7.5  Depot x month service summary - small and fast, for trend visuals
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_depot_month') IS NOT NULL DROP VIEW dbo.vw_pbi_depot_month;
GO
CREATE VIEW dbo.vw_pbi_depot_month AS
SELECT
    o.depot_id,
    DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1)                  AS month_start,
    COUNT(*)                                                                   AS order_lines,
    CAST(100.0 * AVG(CASE WHEN o.on_time_flag = 1 AND o.in_full_flag = 1
                          THEN 1.0 ELSE 0.0 END) AS DECIMAL(5,2))              AS otif_pct,
    CAST(100.0 * AVG(CAST(o.on_time_flag AS DECIMAL(5,2))) AS DECIMAL(5,2))    AS on_time_pct,
    CAST(100.0 * AVG(CAST(o.in_full_flag AS DECIMAL(5,2))) AS DECIMAL(5,2))    AS in_full_pct,
    CAST(SUM(o.delivered_qty_l) / 1000.0 AS DECIMAL(12,1))                     AS delivered_kl,
    CAST(SUM(o.ordered_qty_l - o.delivered_qty_l) / 1000.0 AS DECIMAL(12,1))   AS unfilled_kl,
    CAST(SUM(o.freight_cost_inr) / 100000.0 AS DECIMAL(12,2))                  AS freight_lakh,
    CAST(SUM((o.ordered_qty_l - o.delivered_qty_l)
             * (k.list_price_inr_per_l - k.std_cost_inr_per_l)) / 100000.0
         AS DECIMAL(12,2))                                                     AS lost_margin_lakh
FROM dbo.fact_order_line o
JOIN dbo.dim_sku k ON k.sku_id = o.sku_id
GROUP BY o.depot_id, DATEFROMPARTS(YEAR(o.order_date), MONTH(o.order_date), 1);
GO

/* ---------------------------------------------------------------------------
   7.6  Stock position - depot x sku x week, for the inventory page
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_stock') IS NOT NULL DROP VIEW dbo.vw_pbi_stock;
GO
CREATE VIEW dbo.vw_pbi_stock AS
SELECT
    s.depot_id, s.sku_id, s.week_start_date,
    s.opening_stock_l, s.receipts_l, s.planned_receipts_l,
    s.dispatches_l, s.writeoff_l, s.closing_stock_l, s.stockout_days,
    s.closing_stock_l * k.std_cost_inr_per_l                      AS closing_stock_value_inr,
    s.writeoff_l * k.std_cost_inr_per_l                           AS writeoff_value_inr,
    CASE WHEN s.receipts_l < s.planned_receipts_l * 0.90 THEN 1 ELSE 0 END AS short_supplied_flag
FROM dbo.fact_depot_stock_weekly s
JOIN dbo.dim_sku k ON k.sku_id = s.sku_id;
GO

/* ---------------------------------------------------------------------------
   7.7  Capacity headroom - six rows, feeds the stress-test visual
   ------------------------------------------------------------------------ */
IF OBJECT_ID('dbo.vw_pbi_capacity') IS NOT NULL DROP VIEW dbo.vw_pbi_capacity;
GO
CREATE VIEW dbo.vw_pbi_capacity AS
WITH weekly AS (
    SELECT depot_id, week_start_date, SUM(dispatches_l) / 1000.0 AS kl
    FROM dbo.fact_depot_stock_weekly
    GROUP BY depot_id, week_start_date
)
SELECT
    d.depot_id, d.depot_name, d.region, d.distance_km,
    d.throughput_capacity_kl_per_week                                              AS capacity_kl_per_week,
    CAST(AVG(w.kl) AS DECIMAL(10,1))                                               AS avg_week_kl,
    CAST(MAX(w.kl) AS DECIMAL(10,1))                                               AS peak_week_kl,
    CAST(100.0 * AVG(w.kl) / d.throughput_capacity_kl_per_week AS DECIMAL(6,1))    AS avg_utilisation_pct,
    CAST(100.0 * MAX(w.kl) / d.throughput_capacity_kl_per_week AS DECIMAL(6,1))    AS peak_utilisation_pct,
    SUM(CASE WHEN w.kl > d.throughput_capacity_kl_per_week THEN 1 ELSE 0 END)      AS weeks_over_capacity,
    CAST(d.throughput_capacity_kl_per_week / NULLIF(AVG(w.kl), 0) AS DECIMAL(6,2)) AS breach_multiple
FROM weekly w
JOIN dbo.dim_depot d ON d.depot_id = w.depot_id
GROUP BY d.depot_id, d.depot_name, d.region, d.distance_km, d.throughput_capacity_kl_per_week;
GO

PRINT 'Views created. Connect Power BI to: dim_depot, dim_distributor, vw_pbi_sku,';
PRINT 'vw_pbi_date, vw_pbi_order_line, vw_pbi_supplier_scorecard, vw_pbi_depot_month,';
PRINT 'vw_pbi_stock, vw_pbi_capacity';
GO
