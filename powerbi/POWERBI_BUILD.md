# Power BI build guide

Three pages, roughly three to four hours if you follow this in order. Every
measure is copy-paste. Build page 1 completely before starting page 2 — a
half-finished report on day 4 is worse than one finished page.

---

## 0. Before you open Power BI

Run `sql/07_powerbi_views.sql`. Power BI connects to the views, not the raw
tables. If anyone asks why: the business definitions (what counts as OTIF, how
ABC classes are cut, how lost margin is valued) live in one place in the
database, so a change there flows to every visual. Definitions copied into DAX
in five places drift apart, and then two slides disagree.

---

## 1. Connect and load

1. **Home → Get Data → SQL Server**
2. Server: `localhost` (or `.\SQLEXPRESS` if that is your instance name)
   Database: `LubeSupplyChain`
   Data Connectivity mode: **Import** — not DirectQuery. The model is small
   enough to fit in memory and Import is far faster to work with.
3. Select these nine objects:

   | Object | Rows | Role |
   |---|---|---|
   | `vw_pbi_order_line` | ~350k | the fact table |
   | `vw_pbi_sku` | 120 | product dimension, ABC class attached |
   | `dim_depot` | 6 | depot dimension |
   | `dim_distributor` | 300 | customer dimension |
   | `vw_pbi_date` | ~1,100 | date dimension |
   | `vw_pbi_supplier_scorecard` | 24 | page 2 |
   | `vw_pbi_depot_month` | 216 | fast trend visuals |
   | `vw_pbi_stock` | ~97k | page 3 |
   | `vw_pbi_capacity` | 6 | page 3 |

4. **Load**. It will take a minute or two on the order line view.

---

## 2. Build the model

Go to **Model view** and drag these relationships. All are one-to-many, with
the arrow pointing from the dimension into the fact.

```
vw_pbi_date[date_key]              1 --- *  vw_pbi_order_line[order_date]
vw_pbi_sku[sku_id]                 1 --- *  vw_pbi_order_line[sku_id]
dim_depot[depot_id]                1 --- *  vw_pbi_order_line[depot_id]
dim_distributor[distributor_id]    1 --- *  vw_pbi_order_line[distributor_id]

dim_depot[depot_id]                1 --- *  vw_pbi_depot_month[depot_id]
vw_pbi_date[date_key]              1 --- *  vw_pbi_depot_month[month_start]
dim_depot[depot_id]                1 --- *  vw_pbi_stock[depot_id]
vw_pbi_sku[sku_id]                 1 --- *  vw_pbi_stock[sku_id]
dim_depot[depot_id]                1 --- *  vw_pbi_capacity[depot_id]
```

`vw_pbi_supplier_scorecard` stays unconnected. It is a standalone table for
page 2 and joining it to anything would only create ambiguity.

Then: click `vw_pbi_date` in the Fields pane → **Table tools → Mark as date
table** → choose `date_key`. Time intelligence will not work reliably without
this, and this is the single most common reason a Power BI date slicer
misbehaves.

**Cross-filter direction stays Single on every relationship.** If a visual
seems not to filter, fix the visual, not the relationship — switching to Both
is what creates ambiguous paths and wrong totals later.

---

## 3. Measures

Create a home for them first: **Home → Enter Data → Table name `_Measures` →
Load**, then delete its one blank column. Every measure below goes in that
table so they sit together at the top of the field list rather than scattered
across the tables.

For each one: right-click `_Measures` → **New measure**, paste, Enter.

### Service

```dax
Order Lines = COUNTROWS('vw_pbi_order_line')
```
```dax
OTIF % =
DIVIDE (
    SUMX ( 'vw_pbi_order_line', 'vw_pbi_order_line'[otif_flag] ),
    COUNTROWS ( 'vw_pbi_order_line' )
)
```
```dax
On Time % =
DIVIDE (
    SUMX ( 'vw_pbi_order_line', 'vw_pbi_order_line'[on_time_flag] ),
    COUNTROWS ( 'vw_pbi_order_line' )
)
```
```dax
In Full % =
DIVIDE (
    SUMX ( 'vw_pbi_order_line', 'vw_pbi_order_line'[in_full_flag] ),
    COUNTROWS ( 'vw_pbi_order_line' )
)
```
Format all three as **Percentage, 1 decimal** (Measure tools → Format).

```dax
OTIF Target = 0.92
```
```dax
OTIF Gap to Target = [OTIF %] - [OTIF Target]
```

### Volume and money

```dax
Delivered kL = SUM ( 'vw_pbi_order_line'[delivered_qty_l] ) / 1000
```
```dax
Unfilled kL = SUM ( 'vw_pbi_order_line'[unfilled_qty_l] ) / 1000
```
```dax
Lost Margin Cr = SUM ( 'vw_pbi_order_line'[lost_margin_inr] ) / 10000000
```
```dax
Gross Margin Cr = SUM ( 'vw_pbi_order_line'[gross_margin_inr] ) / 10000000
```
```dax
Freight Cr = SUM ( 'vw_pbi_order_line'[freight_cost_inr] ) / 10000000
```
```dax
Freight per Litre =
DIVIDE (
    SUM ( 'vw_pbi_order_line'[freight_cost_inr] ),
    SUM ( 'vw_pbi_order_line'[delivered_qty_l] )
)
```
```dax
Cost to Serve per Litre =
DIVIDE (
    SUM ( 'vw_pbi_order_line'[freight_cost_inr] )
        + SUM ( 'vw_pbi_order_line'[lost_margin_inr] ),
    SUM ( 'vw_pbi_order_line'[delivered_qty_l] )
)
```
Format the three "Cr" measures as **Decimal, 2 places**, and the two per-litre
measures as **Decimal, 2 places** as well.

### Annualised, so the card reads as a run rate not a three-year total

```dax
Lost Margin Cr per Year = DIVIDE ( [Lost Margin Cr], 3 )
```
Use this on cards. Three years of data on a KPI card invites the question
"is that per year?" — answer it before it is asked.

### Trend

```dax
OTIF % LM = CALCULATE ( [OTIF %], DATEADD ( 'vw_pbi_date'[date_key], -1, MONTH ) )
```
```dax
OTIF % MoM = [OTIF %] - [OTIF % LM]
```

### Page 2, supplier

```dax
Production Lost kL = SUM ( 'vw_pbi_supplier_scorecard'[production_lost_kl] )
```
```dax
Supplier Spend Cr = SUM ( 'vw_pbi_supplier_scorecard'[spend_cr] )
```
```dax
Margin Lost Cr = SUM ( 'vw_pbi_supplier_scorecard'[margin_lost_cr] )
```

### Page 3, inventory

```dax
Closing Stock Value Cr = SUM ( 'vw_pbi_stock'[closing_stock_value_inr] ) / 10000000
```
```dax
Avg Stock Value Cr =
DIVIDE ( SUM ( 'vw_pbi_stock'[closing_stock_value_inr] ) / 10000000,
         DISTINCTCOUNT ( 'vw_pbi_stock'[week_start_date] ) )
```
```dax
Weeks of Cover =
DIVIDE ( SUM ( 'vw_pbi_stock'[closing_stock_l] ),
         SUM ( 'vw_pbi_stock'[dispatches_l] ) )
```
```dax
Short Supplied Weeks % =
DIVIDE (
    SUMX ( 'vw_pbi_stock', 'vw_pbi_stock'[short_supplied_flag] ),
    COUNTROWS ( 'vw_pbi_stock' )
)
```

---

## 4. Page 1 — Service performance

Rename the page tab to **Service**. This page answers "how are we doing and
where is it going wrong". It is the one you screenshot for your CV.

**Top row — four KPI cards** (Visualizations → Card)

| Card | Field | Note |
|---|---|---|
| OTIF | `[OTIF %]` | add a subtitle text box: "target 92%" |
| On time | `[On Time %]` | |
| In full | `[In Full %]` | |
| Margin lost | `[Lost Margin Cr per Year]` | title it "Rs Cr lost per year" |

**Middle left — OTIF trend** (Line chart)
- X axis: `vw_pbi_date[month_start]`
- Y axis: `[OTIF %]`
- Add a constant line at 0.92: select the visual → **Format → Analytics →
  Constant line → Value 0.92**, colour it grey, turn its data label on and name
  it "target".
- Y axis: turn OFF "Start at zero" (Format → Y axis → Range → Start = 0.8).
  A service chart pinned to zero hides the entire story.

**Middle right — where service is lost** (Stacked bar chart)
- Y axis: `dim_depot[depot_name]`
- X axis: `[Order Lines]`
- Legend: `vw_pbi_order_line[fail_reason_label]`
- Sort by the depot's OTIF, not alphabetically: click the visual's `...` →
  Sort axis. Better still, use `[OTIF %]` on a second visual beside it.
- Under Format → Legend, move it to the bottom.

**Bottom left — failure mix** (Clustered bar)
- Y axis: `fail_reason_label`, X axis: `[Unfilled kL]`
- Filter out "Delivered as promised" (drag `fail_reason_label` into the
  visual's Filters pane → uncheck it). Leaving it in makes every other bar
  invisible, which is the most common chart mistake in this dataset.

**Bottom right — service against distance** (Scatter)
- X axis: `dim_depot[distance_km]`
- Y axis: `[OTIF %]`
- Size: `[Delivered kL]`
- Details: `dim_depot[depot_name]`
- This one visual makes the argument that service degrades with distance. Turn
  on Format → Analytics → Trend line.

**Slicers down the left edge** (or across the top)
- `vw_pbi_date[month_start]` as a **Between** slicer
- `dim_depot[region]`
- `vw_pbi_sku[segment_name]`
- `vw_pbi_sku[abc_class]`

Set every slicer's Format → Slicer settings → Options → Style so they look
consistent, and switch on **View → Sync slicers** so the date slicer applies to
all three pages.

---

## 5. Page 2 — Supplier risk

Rename the tab **Suppliers**. This page carries the strongest finding, so give
it room.

**The scatter, top left, large** — this is the money visual
- X axis: `vw_pbi_supplier_scorecard[price_per_kg]`
- Y axis: `vw_pbi_supplier_scorecard[production_lost_kl]`
- Size: `vw_pbi_supplier_scorecard[spend_cr]`
- Legend: `vw_pbi_supplier_scorecard[material_type]`
- Details: `supplier_name`
- Title: **"Cheapest per kg, most expensive in practice"**

The story reads itself: the suppliers furthest left (cheapest) sit highest
(most production lost). Add data labels (Format → Data labels → on) so the
three outliers are named on the chart.

**Top right — inbound reliability** (Clustered bar)
- Y axis: `supplier_name`
- X axis: `inbound_otif_pct`
- Add a second value: `lead_time_sd_days` on a line, or keep it simple and put
  SD in the tooltip.
- Colour by `sourcing` (Imported vs Domestic) — the split is the point.

**Bottom — the scorecard table** (Table visual, not Matrix)

Columns in this order: `supplier_name`, `material_type`, `sourcing`,
`contract_lead_time_days`, `actual_lead_time_days`, `lead_time_sd_days`,
`inbound_otif_pct`, `price_per_kg`, `true_cost_per_kg`, `production_lost_kl`,
`action_quadrant`.

Then add conditional formatting, which is what makes a table look considered
rather than dumped:
- `inbound_otif_pct` → Format → Cell elements → **Background colour** → Rules:
  red below 40, amber 40–70, green above 70.
- `production_lost_kl` → Cell elements → **Data bars**.
- Sort by `production_lost_kl` descending.

**One text box** with the finding in a sentence. Something like: *"In all three
material categories the lowest-priced supplier is also the one that cost us the
most production. Price per kg is the wrong ranking."*

---

## 6. Page 3 — Inventory and capacity

Rename the tab **Inventory & capacity**.

**Top — three cards**
- `[Avg Stock Value Cr]` titled "Average stock held, Rs Cr"
- `[Short Supplied Weeks %]` titled "Depot-SKU weeks under-supplied"
- A text box with the misallocation headline. This number comes from query 5.1
  and cannot be computed from the imported views, so state it as text: *"86.6%
  of unfilled volume was in another depot the same week."* Put the SQL script
  name next to it in small type so the source is traceable.

**Left — weeks of cover** (Matrix)
- Rows: `dim_depot[depot_name]`
- Columns: `vw_pbi_sku[abc_class]`
- Values: `[Weeks of Cover]`
- Format → Cell elements → Background colour, low = green, high = red.

**Right — capacity headroom** (Clustered column with a line)
- Use the **Line and stacked column chart**
- X axis: `vw_pbi_capacity[depot_name]`
- Column: `avg_week_kl` and `peak_week_kl`
- Line: `capacity_kl_per_week`
- The visual makes its own point: two depots have their peak above the line.

**Bottom — stock and dispatch over time** (Area or line chart)
- X axis: `vw_pbi_stock[week_start_date]`
- Y: `[Closing Stock Value Cr]`
- Add `[Short Supplied Weeks %]` on a secondary axis if it does not get busy.

---

## 7. Finishing, in the last 30 minutes

These are what separate a report that looks built from one that looks
finished, and they cost almost no time:

- **Titles.** Every visual gets a title that states a finding, not a field
  name. "OTIF by depot" is a label; "Service falls 6.6 points from Bhiwandi to
  Kolkata" is a finding. Format → General → Title.
- **One accent colour.** View → Themes → pick one, and stop there. Do not
  colour every series differently.
- **Turn off gridlines** on the bar charts (Format → Y axis → Gridlines off).
- **Units in the titles**, always: kL, Rs Cr, %.
- **Tooltips.** Add `[Order Lines]` to each visual's tooltip field well so
  hovering shows how much data is behind a bar. It pre-empts "is that based on
  ten orders or ten thousand?"
- **A footer text box** on page 1: data period, row count, and the words
  "synthetic dataset, calibrated to published Indian lubricants market figures
  — see CALIBRATION.md". Never let someone discover that on their own.
- **File → Export → Export to PDF** and keep the PDF. It is what you attach to
  an application when nobody wants to install anything.

---

## Troubleshooting

**"Can't connect to SQL Server"** — use `localhost` first; if that fails open
SQL Server Configuration Manager and check the instance name, then try
`.\SQLEXPRESS`. Also make sure SQL Server Browser service is running.

**Blank visuals after adding a slicer** — almost always a missing relationship,
or a relationship pointing the wrong way. Model view, check the arrow direction:
it must run from the dimension to the fact.

**"Column not found" after you edit a view** — Home → Refresh, then Transform
data → Refresh Preview. Power BI caches the schema, not just the data.

**The date slicer shows dates from 1899** — you forgot to Mark as date table,
or a relationship is joining a date to a text column.

**Report is slow** — you are probably filtering `vw_pbi_order_line` in a card
that could use `vw_pbi_depot_month` instead. The pre-aggregated view exists
exactly for that.
