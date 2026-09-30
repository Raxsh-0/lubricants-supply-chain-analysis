"""
Signal validation
=================
Runs the same logic the SQL scripts run, straight over the CSVs, and prints the
numbers that the documentation quotes. If a number appears in a doc, it was
printed by this file first. Nothing is asserted from the generator's intent.
"""
import duckdb, textwrap
from pathlib import Path

D = Path(__file__).resolve().parent.parent / "data"
con = duckdb.connect()
for t in ["dim_sku", "dim_depot", "dim_distributor", "dim_supplier",
          "fact_inbound_po", "fact_production_batch", "fact_depot_stock_weekly",
          "fact_order_line"]:
    con.execute(f"CREATE VIEW {t} AS SELECT * FROM read_csv_auto('{D/f'{t}.csv'}')")

def show(title, sql):
    print("\n" + "=" * 78)
    print(title)
    print("=" * 78)
    print(con.execute(textwrap.dedent(sql)).df().to_string(index=False))

# --------------------------------------------------------------- Q1 service
show("Q1a  Network service level", """
    SELECT COUNT(*) AS order_lines,
           ROUND(100.0*AVG(on_time_flag),2) AS on_time_pct,
           ROUND(100.0*AVG(in_full_flag),2) AS in_full_pct,
           ROUND(100.0*AVG(CASE WHEN on_time_flag=1 AND in_full_flag=1 THEN 1 ELSE 0 END),2) AS otif_pct,
           ROUND(SUM(ordered_qty_l)/1e6,1) AS ordered_ml,
           ROUND(SUM(delivered_qty_l)/1e6,1) AS delivered_ml
    FROM fact_order_line
""")

show("Q1b  OTIF by depot", """
    SELECT o.depot_id, d.depot_name, d.std_transit_days AS transit_d,
           COUNT(*) AS lines,
           ROUND(100.0*AVG(o.on_time_flag),2) AS on_time_pct,
           ROUND(100.0*AVG(o.in_full_flag),2) AS in_full_pct,
           ROUND(100.0*AVG(CASE WHEN o.on_time_flag=1 AND o.in_full_flag=1 THEN 1 ELSE 0 END),2) AS otif_pct
    FROM fact_order_line o JOIN dim_depot d USING (depot_id)
    GROUP BY 1,2,3 ORDER BY otif_pct
""")

show("Q1c  Failure mix, and lost litres by cause", """
    SELECT fail_reason,
           COUNT(*) AS lines,
           ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_of_lines,
           ROUND(SUM(ordered_qty_l-delivered_qty_l)/1000,0) AS lost_kl,
           ROUND(100.0*SUM(ordered_qty_l-delivered_qty_l)/SUM(SUM(ordered_qty_l-delivered_qty_l)) OVER (),1) AS pct_of_lost_volume
    FROM fact_order_line GROUP BY 1 ORDER BY lost_kl DESC
""")

show("Q1d  OTIF by year", """
    SELECT EXTRACT(year FROM order_date) AS yr,
           ROUND(100.0*AVG(CASE WHEN on_time_flag=1 AND in_full_flag=1 THEN 1 ELSE 0 END),2) AS otif_pct,
           ROUND(100.0*AVG(on_time_flag),2) AS on_time_pct
    FROM fact_order_line GROUP BY 1 ORDER BY 1
""")

show("Q1e  Monsoon vs rest of year", """
    SELECT CASE WHEN EXTRACT(month FROM order_date) IN (6,7,8,9) THEN 'Monsoon Jun-Sep' ELSE 'Rest of year' END AS period,
           ROUND(100.0*AVG(CASE WHEN on_time_flag=1 AND in_full_flag=1 THEN 1 ELSE 0 END),2) AS otif_pct,
           ROUND(100.0*AVG(on_time_flag),2) AS on_time_pct,
           ROUND(AVG(freight_cost_inr/NULLIF(delivered_qty_l,0)),3) AS freight_inr_per_l
    FROM fact_order_line WHERE delivered_qty_l>0 GROUP BY 1
""")

# ------------------------------------------------------------- Q2 suppliers
show("Q2a  Supplier lead-time reliability", """
    SELECT s.supplier_id, s.supplier_name, s.material_type, s.origin_hub,
           s.contract_lead_time_days AS contract_lt,
           COUNT(*) AS pos,
           ROUND(AVG(DATE_DIFF('day', p.order_date, p.actual_receipt_date)),1) AS actual_lt,
           ROUND(STDDEV_SAMP(DATE_DIFF('day', p.order_date, p.actual_receipt_date)),1) AS lt_sd,
           ROUND(100.0*AVG(CASE WHEN p.actual_receipt_date<=p.promised_date
                                 AND p.received_qty_kg>=p.ordered_qty_kg*0.97 THEN 1 ELSE 0 END),1) AS inbound_otif_pct,
           SUM(GREATEST(DATE_DIFF('day', p.promised_date, p.actual_receipt_date),0)) AS total_late_days,
           ROUND(AVG(p.unit_price_inr_per_kg),1) AS avg_price_kg
    FROM fact_inbound_po p JOIN dim_supplier s USING (supplier_id)
    GROUP BY 1,2,3,4,5 ORDER BY inbound_otif_pct
""")

show("Q2b  Production delay by reason", """
    SELECT delay_reason, COUNT(*) AS batches,
           ROUND(100.0*COUNT(*)/SUM(COUNT(*)) OVER (),2) AS pct_batches,
           ROUND(AVG(delay_days),2) AS avg_delay_days,
           ROUND(SUM(planned_qty_l-actual_qty_l)/1000,0) AS shortfall_kl,
           ROUND(100.0*SUM(planned_qty_l-actual_qty_l)/SUM(SUM(planned_qty_l-actual_qty_l)) OVER (),1) AS pct_shortfall
    FROM fact_production_batch GROUP BY 1 ORDER BY shortfall_kl DESC
""")

show("Q2c  Which suppliers the delayed batches trace back to (top 10)", """
    SELECT s.supplier_id, s.supplier_name, s.material_type,
           COUNT(*) AS batches_hit,
           ROUND(SUM(b.planned_qty_l-b.actual_qty_l)/1000,1) AS production_shortfall_kl,
           ROUND(AVG(b.delay_days),2) AS avg_batch_delay_days
    FROM fact_production_batch b
    JOIN fact_inbound_po p ON b.causing_po_id = p.po_id
    JOIN dim_supplier s ON s.supplier_id = p.supplier_id
    WHERE b.delay_reason='RAW_MATERIAL_SHORT'
    GROUP BY 1,2,3 ORDER BY production_shortfall_kl DESC LIMIT 10
""")

show("Q2d  Cost inversion: cheapest per kg vs true cost including service failure", """
    WITH sup AS (
      SELECT s.supplier_id, s.supplier_name, s.material_type,
             ROUND(AVG(p.unit_price_inr_per_kg),1) AS price_kg,
             SUM(p.received_qty_kg) AS kg
      FROM fact_inbound_po p JOIN dim_supplier s USING (supplier_id)
      GROUP BY 1,2,3),
    dmg AS (
      SELECT p.supplier_id, SUM(b.planned_qty_l-b.actual_qty_l) AS short_l
      FROM fact_production_batch b JOIN fact_inbound_po p ON b.causing_po_id=p.po_id
      WHERE b.delay_reason='RAW_MATERIAL_SHORT' GROUP BY 1)
    SELECT sup.supplier_id, sup.supplier_name, sup.material_type, sup.price_kg,
           RANK() OVER (PARTITION BY sup.material_type ORDER BY sup.price_kg) AS cheapest_rank,
           ROUND(COALESCE(dmg.short_l,0)/1000,1) AS caused_shortfall_kl,
           RANK() OVER (PARTITION BY sup.material_type ORDER BY COALESCE(dmg.short_l,0) DESC) AS worst_damage_rank
    FROM sup LEFT JOIN dmg USING (supplier_id)
    WHERE sup.material_type IN ('BASE_OIL_G3','ADDITIVE','BASE_OIL_G2')
    ORDER BY sup.material_type, sup.price_kg
""")

# ------------------------------------------------------------------ Q3 cost
show("Q3a  Cost of the service gap", """
    WITH x AS (
      SELECT o.*, k.list_price_inr_per_l - k.std_cost_inr_per_l AS gm_per_l
      FROM fact_order_line o JOIN dim_sku k USING (sku_id))
    SELECT ROUND(SUM(ordered_qty_l-delivered_qty_l)/1000,0) AS unfilled_kl,
           ROUND(SUM((ordered_qty_l-delivered_qty_l)*gm_per_l)/1e7,2) AS lost_gross_margin_cr,
           ROUND(SUM((ordered_qty_l-delivered_qty_l)*gm_per_l)/1e7/3,2) AS lost_gm_cr_per_year,
           ROUND(SUM(CASE WHEN is_emergency_transfer=1 THEN freight_cost_inr END)/1e7,2) AS emergency_freight_cr,
           ROUND(SUM(freight_cost_inr)/1e7,2) AS total_freight_cr
    FROM x
""")

show("Q3b  Emergency transfer premium", """
    SELECT is_emergency_transfer,
           COUNT(*) AS lines,
           ROUND(SUM(delivered_qty_l)/1000,0) AS kl,
           ROUND(SUM(freight_cost_inr)/NULLIF(SUM(delivered_qty_l),0),3) AS freight_inr_per_l
    FROM fact_order_line WHERE delivered_qty_l>0 GROUP BY 1
""")

show("Q3c  Cost-to-serve per litre by depot", """
    WITH x AS (
      SELECT o.depot_id, o.delivered_qty_l, o.freight_cost_inr,
             (o.ordered_qty_l-o.delivered_qty_l)*(k.list_price_inr_per_l-k.std_cost_inr_per_l) AS lost_gm
      FROM fact_order_line o JOIN dim_sku k USING (sku_id))
    SELECT d.depot_id, d.depot_name, d.distance_km,
           ROUND(SUM(x.delivered_qty_l)/1000,0) AS delivered_kl,
           ROUND(SUM(x.freight_cost_inr)/NULLIF(SUM(x.delivered_qty_l),0),3) AS freight_inr_per_l,
           ROUND(SUM(x.lost_gm)/NULLIF(SUM(x.delivered_qty_l),0),3) AS lost_margin_inr_per_l,
           ROUND((SUM(x.freight_cost_inr)+SUM(x.lost_gm))/NULLIF(SUM(x.delivered_qty_l),0),3) AS cost_to_serve_inr_per_l
    FROM x JOIN dim_depot d USING (depot_id)
    GROUP BY 1,2,3 ORDER BY cost_to_serve_inr_per_l DESC
""")

# ------------------------------------------------------------ Q4 assortment
show("Q4a  Volume concentration across SKUs", """
    WITH v AS (
      SELECT sku_id, SUM(delivered_qty_l) AS l FROM fact_order_line GROUP BY 1),
    r AS (
      SELECT sku_id, l, SUM(l) OVER (ORDER BY l DESC) / SUM(l) OVER () AS cum_share,
             ROW_NUMBER() OVER (ORDER BY l DESC) AS rn, COUNT(*) OVER () AS n
      FROM v)
    SELECT CASE WHEN cum_share<=0.80 THEN 'A (top 80% of volume)'
                WHEN cum_share<=0.95 THEN 'B (next 15%)'
                ELSE 'C (last 5%)' END AS abc_class,
           COUNT(*) AS skus,
           ROUND(100.0*COUNT(*)/MAX(n),1) AS pct_of_skus,
           ROUND(SUM(l)/1000,0) AS kl,
           ROUND(100.0*SUM(l)/SUM(SUM(l)) OVER (),1) AS pct_of_volume
    FROM r GROUP BY 1 ORDER BY pct_of_volume DESC
""")

show("Q4b  The tail problem: slow SKUs held at every depot", """
    WITH v AS (SELECT sku_id, SUM(delivered_qty_l) AS l FROM fact_order_line GROUP BY 1),
    r AS (SELECT sku_id, l, SUM(l) OVER (ORDER BY l DESC)/SUM(l) OVER () AS cum FROM v),
    cls AS (SELECT sku_id, CASE WHEN cum<=0.80 THEN 'A' WHEN cum<=0.95 THEN 'B' ELSE 'C' END AS abc FROM r),
    stk AS (
      SELECT s.sku_id, s.depot_id,
             AVG(s.closing_stock_l) AS avg_stock_l,
             SUM(s.dispatches_l) AS disp_l
      FROM fact_depot_stock_weekly s GROUP BY 1,2)
    SELECT c.abc,
           COUNT(*) AS depot_sku_pairs,
           ROUND(AVG(stk.avg_stock_l),0) AS avg_stock_l,
           ROUND(SUM(stk.avg_stock_l*k.std_cost_inr_per_l)/1e7,2) AS stock_value_cr,
           ROUND(100.0*SUM(stk.avg_stock_l*k.std_cost_inr_per_l)/SUM(SUM(stk.avg_stock_l*k.std_cost_inr_per_l)) OVER (),1) AS pct_stock_value,
           ROUND(SUM(stk.disp_l)/NULLIF(SUM(stk.avg_stock_l),0)/3.0,2) AS annual_turns
    FROM stk JOIN cls c USING (sku_id) JOIN dim_sku k ON k.sku_id=stk.sku_id
    GROUP BY 1 ORDER BY 1
""")

show("Q4c  Service and cover by ABC class - the case for range rationalisation", """
    WITH v AS (SELECT sku_id, SUM(delivered_qty_l) AS l FROM fact_order_line GROUP BY 1),
    r AS (SELECT sku_id, l, SUM(l) OVER (ORDER BY l DESC)/SUM(l) OVER () AS cum FROM v),
    cls AS (SELECT sku_id, CASE WHEN cum<=0.80 THEN 'A' WHEN cum<=0.95 THEN 'B' ELSE 'C' END AS abc FROM r),
    svc AS (
      SELECT c.abc,
             ROUND(100.0*AVG(CASE WHEN o.on_time_flag=1 AND o.in_full_flag=1 THEN 1 ELSE 0 END),2) AS otif_pct,
             ROUND(100.0*AVG(o.in_full_flag),2) AS in_full_pct,
             COUNT(*) AS lines
      FROM fact_order_line o JOIN cls c USING (sku_id) GROUP BY 1),
    cov AS (
      SELECT c.abc,
             ROUND(SUM(s.closing_stock_l)/NULLIF(SUM(s.dispatches_l),0),2) AS weeks_of_cover,
             ROUND(SUM(s.writeoff_l)/1000,1) AS writeoff_kl
      FROM fact_depot_stock_weekly s JOIN cls c USING (sku_id) GROUP BY 1)
    SELECT svc.abc, svc.lines, svc.otif_pct, svc.in_full_pct, cov.weeks_of_cover, cov.writeoff_kl
    FROM svc JOIN cov USING (abc) ORDER BY svc.abc
""")

show("Q4d  Cash released by centralising the tail", """
    WITH v AS (SELECT sku_id, SUM(delivered_qty_l) AS l FROM fact_order_line GROUP BY 1),
    r AS (SELECT sku_id, l, SUM(l) OVER (ORDER BY l DESC)/SUM(l) OVER () AS cum FROM v),
    cls AS (SELECT sku_id, CASE WHEN cum<=0.80 THEN 'A' WHEN cum<=0.95 THEN 'B' ELSE 'C' END AS abc FROM r),
    pair AS (
      SELECT s.sku_id, s.depot_id, AVG(s.closing_stock_l) AS avg_stock_l, SUM(s.dispatches_l) AS disp_l
      FROM fact_depot_stock_weekly s GROUP BY 1,2)
    SELECT COUNT(*) AS tail_pairs_outside_two_hubs,
           ROUND(SUM(pair.avg_stock_l*k.std_cost_inr_per_l)/1e7,2) AS working_capital_cr,
           ROUND(SUM(pair.disp_l)/1000,0) AS volume_at_risk_kl
    FROM pair JOIN cls c USING (sku_id) JOIN dim_sku k ON k.sku_id=pair.sku_id
    WHERE c.abc='C' AND pair.depot_id NOT IN ('DEP-BHW','DEP-GUR')
""")

show("Q4e  Worst C-class depot-SKU pairs (candidates to centralise)", """
    WITH v AS (SELECT sku_id, SUM(delivered_qty_l) AS l FROM fact_order_line GROUP BY 1),
    r AS (SELECT sku_id, l, SUM(l) OVER (ORDER BY l DESC)/SUM(l) OVER () AS cum FROM v),
    cls AS (SELECT sku_id, CASE WHEN cum<=0.80 THEN 'A' WHEN cum<=0.95 THEN 'B' ELSE 'C' END AS abc FROM r),
    stk AS (SELECT sku_id, depot_id, AVG(closing_stock_l) AS avg_stock_l, SUM(dispatches_l) AS disp_l
            FROM fact_depot_stock_weekly GROUP BY 1,2)
    SELECT COUNT(*) AS pairs_below_1_turn,
           ROUND(SUM(stk.avg_stock_l*k.std_cost_inr_per_l)/1e7,2) AS trapped_working_capital_cr
    FROM stk JOIN cls c USING (sku_id) JOIN dim_sku k ON k.sku_id=stk.sku_id
    WHERE c.abc='C' AND stk.disp_l/3.0 < stk.avg_stock_l * 2
""")

# -------------------------------------------------------------- Q5 capacity
show("Q5a  Plant utilisation against 159,000 kl/yr nameplate", """
    SELECT EXTRACT(year FROM week_start_date) AS yr,
           ROUND(SUM(actual_qty_l)/1000,0) AS produced_kl,
           COUNT(DISTINCT week_start_date) AS weeks,
           ROUND(100.0*SUM(actual_qty_l)/(COUNT(DISTINCT week_start_date)*159000.0*1000/52),1) AS utilisation_pct
    FROM fact_production_batch GROUP BY 1 ORDER BY 1
""")

show("Q5b  Peak week utilisation and depot throughput headroom", """
    WITH wk AS (
      SELECT s.depot_id, s.week_start_date, SUM(s.dispatches_l)/1000.0 AS kl
      FROM fact_depot_stock_weekly s GROUP BY 1,2)
    SELECT d.depot_id, d.depot_name, d.throughput_capacity_kl_per_week AS cap_kl,
           ROUND(AVG(wk.kl),1) AS avg_kl, ROUND(MAX(wk.kl),1) AS peak_kl,
           ROUND(100.0*MAX(wk.kl)/d.throughput_capacity_kl_per_week,1) AS peak_util_pct,
           ROUND(d.throughput_capacity_kl_per_week/NULLIF(AVG(wk.kl),0),2) AS breach_multiple
    FROM wk JOIN dim_depot d USING (depot_id)
    GROUP BY 1,2,3 ORDER BY breach_multiple
""")

show("Q5c  Storage headroom at recent run rate", """
    WITH perwk AS (
      SELECT depot_id, week_start_date, SUM(closing_stock_l)/1000.0 AS stock_kl
      FROM fact_depot_stock_weekly
      WHERE week_start_date >= DATE '2025-09-01' GROUP BY 1,2),
    last52 AS (SELECT depot_id, AVG(stock_kl) AS avg_stock_kl FROM perwk GROUP BY 1)
    SELECT d.depot_id, d.depot_name, d.storage_capacity_kl,
           ROUND(l.avg_stock_kl,0) AS avg_stock_kl,
           ROUND(100.0*l.avg_stock_kl/d.storage_capacity_kl,1) AS storage_util_pct
    FROM last52 l JOIN dim_depot d USING (depot_id) ORDER BY storage_util_pct DESC
""")

# ------------------------------------------------------------ data integrity
show("Q0  Data quality audit", """
    SELECT 'order lines with NULL delivery date' AS check_name,
           SUM(CASE WHEN actual_delivery_date IS NULL THEN 1 ELSE 0 END) AS n,
           COUNT(*) AS total FROM fact_order_line
    UNION ALL SELECT 'delivered > ordered',
           SUM(CASE WHEN delivered_qty_l > ordered_qty_l + 0.51 THEN 1 ELSE 0 END), COUNT(*) FROM fact_order_line
    UNION ALL SELECT 'stock balance broken (open+recv-disp <> close)',
           SUM(CASE WHEN ABS(opening_stock_l+receipts_l-dispatches_l-writeoff_l-closing_stock_l) > 1.0 THEN 1 ELSE 0 END), COUNT(*)
           FROM fact_depot_stock_weekly
    UNION ALL SELECT 'PO received before ordered',
           SUM(CASE WHEN actual_receipt_date < order_date THEN 1 ELSE 0 END), COUNT(*) FROM fact_inbound_po
    UNION ALL SELECT 'orphan sku in order lines',
           SUM(CASE WHEN k.sku_id IS NULL THEN 1 ELSE 0 END), COUNT(*)
           FROM fact_order_line o LEFT JOIN dim_sku k USING (sku_id)
""")
