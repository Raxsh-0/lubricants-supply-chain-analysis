/* ============================================================================
   Lubricants Distribution Network - schema
   Microsoft SQL Server / SSMS

   Run order:  00 -> 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07
   Run this whole file once. It is safe to re-run: it drops and rebuilds.
   ========================================================================= */

IF DB_ID('LubeSupplyChain') IS NULL
    CREATE DATABASE LubeSupplyChain;
GO

USE LubeSupplyChain;
GO

/* Drop in dependency order (facts first, then dimensions). ---------------- */
IF OBJECT_ID('dbo.fact_order_line')          IS NOT NULL DROP TABLE dbo.fact_order_line;
IF OBJECT_ID('dbo.fact_depot_stock_weekly')  IS NOT NULL DROP TABLE dbo.fact_depot_stock_weekly;
IF OBJECT_ID('dbo.fact_production_batch')    IS NOT NULL DROP TABLE dbo.fact_production_batch;
IF OBJECT_ID('dbo.fact_inbound_po')          IS NOT NULL DROP TABLE dbo.fact_inbound_po;
IF OBJECT_ID('dbo.dim_distributor')          IS NOT NULL DROP TABLE dbo.dim_distributor;
IF OBJECT_ID('dbo.dim_supplier')             IS NOT NULL DROP TABLE dbo.dim_supplier;
IF OBJECT_ID('dbo.dim_depot')                IS NOT NULL DROP TABLE dbo.dim_depot;
IF OBJECT_ID('dbo.dim_sku')                  IS NOT NULL DROP TABLE dbo.dim_sku;
GO

/* ---------------------------------------------------------------- DIMENSIONS */

CREATE TABLE dbo.dim_sku (
    sku_id                VARCHAR(10)   NOT NULL PRIMARY KEY,
    sku_name              VARCHAR(80)   NOT NULL,
    segment_code          VARCHAR(6)    NOT NULL,   -- PCMO / MCO / HDD / IND / GRE / MET
    segment_name          VARCHAR(40)   NOT NULL,
    tier_code             VARCHAR(4)    NOT NULL,   -- SYN / SEM / MIN
    base_oil_group        VARCHAR(4)    NOT NULL,   -- I / II / III
    pack_size_l           DECIMAL(9,2)  NOT NULL,
    list_price_inr_per_l  DECIMAL(10,2) NOT NULL,
    std_cost_inr_per_l    DECIMAL(10,2) NOT NULL,
    shelf_life_months     INT           NOT NULL
);

CREATE TABLE dbo.dim_depot (
    depot_id                        VARCHAR(10)  NOT NULL PRIMARY KEY,
    depot_name                      VARCHAR(40)  NOT NULL,
    region                          VARCHAR(20)  NOT NULL,
    distance_km                     INT          NOT NULL,
    std_transit_days                INT          NOT NULL,
    storage_capacity_kl             INT          NOT NULL,
    throughput_capacity_kl_per_week INT          NOT NULL,
    primary_freight_inr_per_l       DECIMAL(9,3) NOT NULL,
    secondary_freight_inr_per_l     DECIMAL(9,3) NOT NULL
);

CREATE TABLE dbo.dim_distributor (
    distributor_id   VARCHAR(10) NOT NULL PRIMARY KEY,
    distributor_name VARCHAR(80) NOT NULL,
    depot_id         VARCHAR(10) NOT NULL,
    city             VARCHAR(40) NOT NULL,
    channel          VARCHAR(20) NOT NULL,   -- AUTO_RETAIL / WORKSHOP_OEM / INDUSTRIAL_B2B / FLEET
    tier             VARCHAR(2)  NOT NULL,   -- A / B / C
    credit_days      INT         NOT NULL,
    onboard_date     DATE        NOT NULL
);

CREATE TABLE dbo.dim_supplier (
    supplier_id               VARCHAR(10)   NOT NULL PRIMARY KEY,
    supplier_name             VARCHAR(60)   NOT NULL,
    material_type             VARCHAR(20)   NOT NULL,  -- BASE_OIL_G1/G2/G3, ADDITIVE, PACKAGING, THICKENER, SOLVENT
    origin_hub                VARCHAR(30)   NOT NULL,
    contract_lead_time_days   INT           NOT NULL,
    contract_price_inr_per_kg DECIMAL(10,2) NOT NULL
);

/* --------------------------------------------------------------------- FACTS */
/* NOTE ON TYPES: every quantity column is DECIMAL, never INT. The CSVs write
   whole numbers as "460.0", and BULK INSERT fails on that if the column is INT.
   Flag columns are genuine 0/1 integers and are safe as TINYINT.             */

CREATE TABLE dbo.fact_inbound_po (
    po_id                 VARCHAR(12)   NOT NULL PRIMARY KEY,
    supplier_id           VARCHAR(10)   NOT NULL,
    material_type         VARCHAR(20)   NOT NULL,
    order_date            DATE          NOT NULL,
    promised_date         DATE          NOT NULL,
    actual_receipt_date   DATE          NOT NULL,
    ordered_qty_kg        DECIMAL(14,2) NOT NULL,
    received_qty_kg       DECIMAL(14,2) NOT NULL,
    unit_price_inr_per_kg DECIMAL(10,2) NOT NULL,
    qc_hold_days          INT           NOT NULL,
    po_value_inr          DECIMAL(16,2) NOT NULL
);

CREATE TABLE dbo.fact_production_batch (
    batch_id           VARCHAR(12)   NOT NULL PRIMARY KEY,
    sku_id             VARCHAR(10)   NOT NULL,
    plant_id           VARCHAR(10)   NOT NULL,
    week_start_date    DATE          NOT NULL,
    planned_start_date DATE          NOT NULL,
    actual_start_date  DATE          NOT NULL,
    planned_qty_l      DECIMAL(14,2) NOT NULL,
    actual_qty_l       DECIMAL(14,2) NOT NULL,
    delay_days         INT           NOT NULL,
    delay_reason       VARCHAR(24)   NOT NULL,   -- NONE / RAW_MATERIAL_SHORT / CHANGEOVER / QUALITY_HOLD / MAINTENANCE
    causing_po_id      VARCHAR(12)   NULL        -- the PO that starved this batch, when there was one
);

CREATE TABLE dbo.fact_depot_stock_weekly (
    depot_id           VARCHAR(10)   NOT NULL,
    sku_id             VARCHAR(10)   NOT NULL,
    week_start_date    DATE          NOT NULL,
    opening_stock_l    DECIMAL(14,2) NOT NULL,
    receipts_l         DECIMAL(14,2) NOT NULL,
    planned_receipts_l DECIMAL(14,2) NOT NULL,
    dispatches_l       DECIMAL(14,2) NOT NULL,
    writeoff_l         DECIMAL(14,2) NOT NULL,
    closing_stock_l    DECIMAL(14,2) NOT NULL,
    stockout_days      INT           NOT NULL,
    CONSTRAINT pk_stock PRIMARY KEY (depot_id, sku_id, week_start_date)
);

CREATE TABLE dbo.fact_order_line (
    order_line_id          VARCHAR(14)   NOT NULL PRIMARY KEY,
    order_date             DATE          NOT NULL,
    distributor_id         VARCHAR(10)   NOT NULL,
    depot_id               VARCHAR(10)   NOT NULL,
    sku_id                 VARCHAR(10)   NOT NULL,
    ordered_qty_l          DECIMAL(14,2) NOT NULL,
    delivered_qty_l        DECIMAL(14,2) NOT NULL,
    promised_delivery_date DATE          NOT NULL,
    actual_delivery_date   DATE          NULL,     -- NULL when nothing shipped
    on_time_flag           TINYINT       NOT NULL,
    in_full_flag           TINYINT       NOT NULL,
    fail_reason            VARCHAR(24)   NOT NULL, -- NONE / DEPOT_STOCKOUT / PLANT_DELAY / TRANSPORT_DELAY / CREDIT_HOLD
    is_emergency_transfer  TINYINT       NOT NULL,
    freight_cost_inr       DECIMAL(14,2) NOT NULL
);
GO

PRINT 'Schema created. Next: run 01_load_data.sql';
GO
