/* ============================================================================
   01 - Load the CSVs, then audit what landed
   ============================================================================
   BEFORE RUNNING: change @path below to the folder holding the CSV files, and
   keep the trailing backslash. The SQL Server service account must be able to
   read that folder, so put the data somewhere like C:\LubeData\ rather than
   inside your user profile - a path under C:\Users\... often fails with
   "Cannot bulk load because the file could not be opened. Operating system
   error code 5 (Access is denied)".

   If BULK INSERT is blocked on your machine for any reason, the fallback is
   SSMS -> right-click the database -> Tasks -> Import Flat File, once per
   table. Slower, but it produces the same result.
   ========================================================================= */

USE LubeSupplyChain;
GO

DECLARE @path NVARCHAR(400) = N'C:\LubeData\';      -- <<< EDIT THIS LINE
DECLARE @sql  NVARCHAR(MAX);

/* Every load uses the same options:
     FORMAT='CSV'   - handles the header and quoting rules properly
     FIRSTROW=2     - skip the header line
     TABLOCK        - much faster on an empty heap
     ROWTERMINATOR  - '0x0a' because the files are written with UNIX line endings */
DECLARE @opts NVARCHAR(400) =
    N' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','', ROWTERMINATOR=''0x0a'', TABLOCK);';

TRUNCATE TABLE dbo.fact_order_line;
TRUNCATE TABLE dbo.fact_depot_stock_weekly;
TRUNCATE TABLE dbo.fact_production_batch;
TRUNCATE TABLE dbo.fact_inbound_po;
DELETE FROM dbo.dim_distributor;
DELETE FROM dbo.dim_supplier;
DELETE FROM dbo.dim_depot;
DELETE FROM dbo.dim_sku;

SET @sql =
    N'BULK INSERT dbo.dim_sku                 FROM ''' + @path + N'dim_sku.csv''' + @opts +
    N'BULK INSERT dbo.dim_depot               FROM ''' + @path + N'dim_depot.csv''' + @opts +
    N'BULK INSERT dbo.dim_distributor         FROM ''' + @path + N'dim_distributor.csv''' + @opts +
    N'BULK INSERT dbo.dim_supplier            FROM ''' + @path + N'dim_supplier.csv''' + @opts +
    N'BULK INSERT dbo.fact_inbound_po         FROM ''' + @path + N'fact_inbound_po.csv''' + @opts +
    N'BULK INSERT dbo.fact_production_batch   FROM ''' + @path + N'fact_production_batch.csv''' + @opts +
    N'BULK INSERT dbo.fact_depot_stock_weekly FROM ''' + @path + N'fact_depot_stock_weekly.csv''' + @opts +
    N'BULK INSERT dbo.fact_order_line         FROM ''' + @path + N'fact_order_line.csv''' + @opts;

EXEC sp_executesql @sql;
GO

/* Indexes go on AFTER the load - building them first slows the load down.
   Dropped first so this file can be re-run from the top without erroring. */
DROP INDEX IF EXISTS ix_ol_depot_date ON dbo.fact_order_line;
DROP INDEX IF EXISTS ix_ol_sku        ON dbo.fact_order_line;
DROP INDEX IF EXISTS ix_ol_dist       ON dbo.fact_order_line;
DROP INDEX IF EXISTS ix_pb_sku        ON dbo.fact_production_batch;
DROP INDEX IF EXISTS ix_pb_po         ON dbo.fact_production_batch;
DROP INDEX IF EXISTS ix_po_supplier   ON dbo.fact_inbound_po;
GO

CREATE INDEX ix_ol_depot_date ON dbo.fact_order_line (depot_id, order_date) INCLUDE (ordered_qty_l, delivered_qty_l, on_time_flag, in_full_flag, fail_reason);
CREATE INDEX ix_ol_sku        ON dbo.fact_order_line (sku_id);
CREATE INDEX ix_ol_dist       ON dbo.fact_order_line (distributor_id);
CREATE INDEX ix_pb_sku        ON dbo.fact_production_batch (sku_id, week_start_date);
CREATE INDEX ix_pb_po         ON dbo.fact_production_batch (causing_po_id);
CREATE INDEX ix_po_supplier   ON dbo.fact_inbound_po (supplier_id);
GO

/* ============================================================================
   Q0  DATA QUALITY AUDIT
   Run this before trusting a single number below it. Every analyst who skips
   this step eventually presents a chart built on broken joins.
   ========================================================================= */

PRINT '--- row counts ---';
SELECT 'dim_sku' AS table_name, COUNT(*) AS rows_loaded, 120     AS rows_expected FROM dbo.dim_sku
UNION ALL SELECT 'dim_depot',               COUNT(*), 6      FROM dbo.dim_depot
UNION ALL SELECT 'dim_distributor',         COUNT(*), 300    FROM dbo.dim_distributor
UNION ALL SELECT 'dim_supplier',            COUNT(*), 24     FROM dbo.dim_supplier
UNION ALL SELECT 'fact_inbound_po',         COUNT(*), 2288   FROM dbo.fact_inbound_po
UNION ALL SELECT 'fact_production_batch',   COUNT(*), 17117  FROM dbo.fact_production_batch
UNION ALL SELECT 'fact_depot_stock_weekly', COUNT(*), 96564  FROM dbo.fact_depot_stock_weekly
UNION ALL SELECT 'fact_order_line',         COUNT(*), 350422 FROM dbo.fact_order_line;

PRINT '--- integrity checks: every "failures" column should be 0 ---';
SELECT 'order lines with no matching SKU' AS check_name,
       SUM(CASE WHEN k.sku_id IS NULL THEN 1 ELSE 0 END) AS failures,
       COUNT(*) AS rows_checked
FROM dbo.fact_order_line o LEFT JOIN dbo.dim_sku k ON k.sku_id = o.sku_id
UNION ALL
SELECT 'order lines with no matching distributor',
       SUM(CASE WHEN d.distributor_id IS NULL THEN 1 ELSE 0 END), COUNT(*)
FROM dbo.fact_order_line o LEFT JOIN dbo.dim_distributor d ON d.distributor_id = o.distributor_id
UNION ALL
SELECT 'delivered quantity greater than ordered',
       SUM(CASE WHEN delivered_qty_l > ordered_qty_l + 0.51 THEN 1 ELSE 0 END), COUNT(*)
FROM dbo.fact_order_line
UNION ALL
SELECT 'stock ledger does not balance',
       SUM(CASE WHEN ABS(opening_stock_l + receipts_l - dispatches_l - writeoff_l - closing_stock_l) > 1.0
                THEN 1 ELSE 0 END), COUNT(*)
FROM dbo.fact_depot_stock_weekly
UNION ALL
SELECT 'PO received before it was ordered',
       SUM(CASE WHEN actual_receipt_date < order_date THEN 1 ELSE 0 END), COUNT(*)
FROM dbo.fact_inbound_po
UNION ALL
SELECT 'in_full flag disagrees with the quantities',
       SUM(CASE WHEN in_full_flag = 1 AND delivered_qty_l < ordered_qty_l - 0.51 THEN 1 ELSE 0 END), COUNT(*)
FROM dbo.fact_order_line;

PRINT '--- expected nulls: these are real, not errors ---';
/* actual_delivery_date is NULL exactly when nothing shipped: a credit hold, or
   a total stockout. Roughly 6.9% of lines. AVG(days late) must exclude them. */
SELECT COUNT(*)                                            AS lines_never_delivered,
       CAST(100.0 * COUNT(*) / (SELECT COUNT(*) FROM dbo.fact_order_line) AS DECIMAL(5,2)) AS pct_of_lines,
       SUM(CASE WHEN fail_reason = 'CREDIT_HOLD' THEN 1 ELSE 0 END) AS of_which_credit_hold
FROM dbo.fact_order_line
WHERE actual_delivery_date IS NULL;

PRINT '--- date coverage ---';
SELECT MIN(order_date) AS first_order, MAX(order_date) AS last_order,
       COUNT(DISTINCT DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)) AS months_covered
FROM dbo.fact_order_line;
GO
