# Data

The four **dimension** tables are committed in full — they are small and define
the schema's vocabulary.

The four **fact** tables are not. Together they are 41 MB, with
`fact_order_line.csv` alone at 35 MB, which makes for a slow clone and a file
GitHub will not render. Instead:

- `sample/` holds the first 2,000 rows of each fact table, so the columns and
  value formats are browsable here.
- The full set regenerates identically with `python ../python/generate_data.py`
  — the simulation seed is fixed at 20260906.

| File | Rows (full) | Grain |
|---|---|---|
| `dim_sku.csv` | 120 | One product |
| `dim_depot.csv` | 6 | One depot |
| `dim_distributor.csv` | 300 | One customer |
| `dim_supplier.csv` | 24 | One raw material vendor |
| `fact_order_line.csv` | 350,422 | One line per distributor order per SKU |
| `fact_depot_stock_weekly.csv` | 96,564 | Depot × SKU × week |
| `fact_production_batch.csv` | 17,117 | One blending run |
| `fact_inbound_po.csv` | 2,288 | One purchase order |

Column meanings are in [`../docs/DATA_DICTIONARY.md`](../docs/DATA_DICTIONARY.md).
