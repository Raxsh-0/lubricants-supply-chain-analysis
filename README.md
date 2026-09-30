# Lubricants Supply Chain — Service & Cost-to-Serve

A SQL Server and Power BI analysis of a lubricant blending plant and its
six-depot distribution network in India. 156 weeks of operational history,
466,841 rows across eight tables, built from a calibrated simulation.

> **How this was built.** The supply chain problem, the questions and the
> interpretation of the results are mine. The code (the data generator, the
> SQL scripts and the Power BI measures) was written with AI assistance.

**The question.** Orders are delivered on time and in full 86.25% of the time
against a 92% industry benchmark. Where is the gap, what does it cost, and what
should be done about it?

**The answer.** The gap is worth about ₹93 crore of gross margin a year. It
looks like an inventory problem — one extra week of cover breaks even at just
8.4% recapture — but **86.6% of the volume that could not be supplied was
physically held in another depot the same week**. So it is an allocation
problem, and buying more stock under the current replenishment rule would
mostly buy more stock in the wrong place. Separately, procurement ranks
suppliers on price per kilogram, and in all three material categories the
cheapest supplier is also the one that cost the most lost production.

---

## The data is synthetic

There is no public dataset for the inside of a lubricants supply chain, so the
data was generated — but calibrated, with every parameter pinned to a published
figure rather than chosen to look plausible. Plant capacity is sized on
ExxonMobil's lubricant facility at Isambe, Raigad (159,000 kL/yr); base oil
prices come from Indian commodity bands; the OTIF benchmark from published
industrial distribution figures. Sources for every parameter are in
[`docs/CALIBRATION.md`](docs/CALIBRATION.md).

The data is not random flags on rows. It is a week-by-week simulation in which
failures emerge from a mechanism: supplier lead-time variance → late material at
the plant → short blending batch (carrying the `causing_po_id` of the purchase
order that starved it) → short depot receipt → stockout → unfilled order line.
That chain is what makes it possible to trace a distributor's unfilled order
back to a specific supplier.

---

## Reproducing it

The full dataset is 41 MB and is **not** committed — the generator is, with a
fixed seed, so the data regenerates identically:

```bash
python python/generate_data.py      # writes the eight CSVs to data/
python python/validate_signal.py    # re-derives every published figure in DuckDB
```

`data/` holds the four dimension tables in full, plus 2,000-row samples of each
fact table in `data/sample/` so the schema is browsable without cloning 41 MB.

Then, in SQL Server Management Studio, run the scripts in order:

| Script | What it does |
|---|---|
| `00_create_database_and_tables.sql` | Schema |
| `01_load_data.sql` | `BULK INSERT` plus a data-quality audit that runs before any analysis |
| `02_service_leakage.sql` | OTIF, failure mix by lines **and** by litres, service vs distance |
| `03_supplier_reliability.sql` | Supplier scorecard splitting lead-time bias from variance; traces lost production to the supplier that caused it |
| `04_cost_to_serve.sql` | Cost of the gap, freight premium, and a parameterised business case |
| `05_inventory_allocation.sql` | ABC classification and the network-availability test |
| `06_capacity_stress_test.sql` | Plant and depot capacity at 1.0×, 1.25×, 1.5×, 2.0× demand |
| `07_powerbi_views.sql` | Nine reporting views (**requires `05` to have run first**) |

---

## Findings

| | |
|---|---|
| OTIF | **86.25%** (on time 88.30%, in full 90.93%) |
| Lost gross margin | **₹92.92 cr/yr** — ₹79.11 cr stock-driven |
| Unfilled volume held elsewhere in the network, same week | **86.6%** |
| Failure mix by lines | Depot stockout 6.42%, transport delay 4.68%, plant delay 1.37%, credit hold 1.28% |
| Failure mix by **litres lost** | Depot stockout 69.4%, transport delay **0.0%**, plant delay 15.2%, credit hold 15.4% |
| OTIF by depot | Bhiwandi 89.50% → Kolkata 82.94%, ordered by transit time |
| Cost to serve | ₹6.94/L (Bhiwandi) → ₹12.77/L (Kolkata); freight is 65% of the gap |
| Emergency freight premium | ₹9.60/L vs ₹3.08/L planned — 3.1× |
| Capacity | Plant at 79–85% of nameplate; one depot over weekly throughput in 64 of 156 weeks |
| Business case | Break-even at 8.4% recapture (18% carrying, 1 extra week); holds from 5.6% to 23.3% across the sensitivity range |

**Counting lines and counting litres give opposite answers.** Transport delay is
the second most frequent failure and costs zero volume — the truck arrives, just
late. Ranking causes by incident count points at a logistics project that would
recover nothing.

**A hypothesis was tested and rejected.** C-class SKUs are 39.2% of the range for
5.1% of volume — the classic shape that triggers a delisting review. But they
return ₹9.0 of gross margin per rupee of stock per year against ₹14.2 for
A-class, and their OTIF is *better* (87.68% vs 86.18%). Cutting the tail
destroys margin. The negative result is kept deliberately.

Full write-up in [`docs/RESULTS.md`](docs/RESULTS.md). Every figure quoted
anywhere in this repo is in [`docs/VERIFIED_FIGURES.md`](docs/VERIFIED_FIGURES.md).

---

## Validation

Every published number is computed twice — once in T-SQL against SQL Server, and
once independently in `python/validate_signal.py` using DuckDB. Different engine,
different code, same question. Nothing was published until the two agreed.

A data-quality audit runs before any analysis: foreign key checks, a stock ledger
that must balance (`opening + receipts − dispatches − write-off = closing`) on
all 96,564 rows, and a check that nothing was delivered in a greater quantity
than it was ordered.

What the analysis does **not** support is documented in
[`docs/LIMITATIONS.md`](docs/LIMITATIONS.md).

---

## Power BI

Three-page report — service performance, supplier reliability, inventory and
capacity. Built on the nine views from script 07, so business definitions live
in the database rather than being duplicated across DAX.

Build instructions and all 23 measures: [`powerbi/`](powerbi/).

---

## Stack

SQL Server (T-SQL — CTEs, window functions, views), Power BI Desktop (DAX),
Python for data generation and validation only. The analysis itself is entirely
SQL.
