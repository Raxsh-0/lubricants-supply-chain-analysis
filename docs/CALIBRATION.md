# Calibration

This dataset is synthetic. This file is the reason that is defensible rather
than embarrassing: every structural parameter is pinned to a published figure,
and the ones that are not are listed at the bottom as assumptions.

If someone asks "where did this data come from?", the honest answer is short:
*there is no public dataset for an internal lubricants supply chain, so I
simulated one against published benchmarks — the analysis is the project, the
data is the input.*

---

## What is modelled

A lubricant blending plant in Raigad, Maharashtra supplying six regional depots
and 300 distributors across India, over 156 weeks (September 2023 to August
2026). Base oils, additives, thickeners, solvents and packaging are bought in
from 24 suppliers, blended into 120 finished SKUs, shipped to depots, and sold
on to distributors in four channels.

---

## Parameters pinned to published figures

| Parameter | Value used | Source |
|---|---|---|
| Plant nameplate capacity | 159,000 kL/year | ExxonMobil's Isambe (Raigad, Maharashtra) lubricant plant — Rs 900 crore investment, 159,000 kL finished-lubricant capacity |
| Network volume | ~130,000 kL/year, i.e. ~82% utilisation | Set so the plant runs at a realistic utilisation rather than at nameplate |
| India lubricants market size | 5.60 billion litres (2025) | Mordor Intelligence, India Lubricants Market |
| Market growth | 3.12% CAGR, applied as a weekly trend | Same source (5.60 bn L 2025 → 6.73 bn L 2031) |
| Automotive share of demand | 54% (PCMO 22%, HDD 20%, MCO 12%) | Automotive end-use 54.15% of the Indian market |
| Mineral vs synthetic mix | 68% mineral / 32% synthetic | Mineral-based products 67.55% of the Indian market |
| Base oil cost, Group I | Rs 78/litre | Rs 85–95/kg × 0.87 kg/l density — OfBusiness India base-oil price bands |
| Base oil cost, Group II | Rs 89/litre | Rs 95–110/kg × 0.87 |
| Base oil cost, Group III | Rs 113/litre | Rs 120–140/kg × 0.87 |
| Import dependence for Group II/III | All Group III and half of Group II sourced from import hubs | India imports the bulk of its Group II and III base oil; Kandla and Mumbai are the main import terminals |
| Primary freight, plant → depot | Rs 0.55 + Rs 0.00195 per km, per litre | Derived from published Indian FTL rates: Rs 12k–35k for 300–700 km, Rs 28k–70k for 700–1,500 km, over an ~18,000 litre load |
| Monsoon freight premium | +9% June–September | Published Indian trucking rates rise 15–20% in peak and monsoon periods; 9% is the conservative end |
| Target OTIF band | 85–92% "good", 92–95% "excellent" | Published 2026 OTIF benchmarks for industrial / heavy goods distribution |
| Gross margin by tier | 24–31% mineral, 32–40% semi-synthetic, 44–52% full synthetic | Standard lubricant industry margin ladder; premium synthetics carry the brand premium |
| Inventory carrying rate | 18% per year | Working capital + warehousing + shrink. A conventional planning figure; query 4.6 lets you change it |
| Safety stock service factor | Z = 1.65 (95% service level) | Standard normal z-score |

---

## Assumptions, chosen not sourced

These are judgement calls. They are listed so nobody has to find them.

| Assumption | Value | Why |
|---|---|---|
| Depot replenishment target | 2.1 weeks of cover | Enough to give a realistic 86% fill rate; below ~1.8 the network breaks, above ~2.6 stockouts vanish and there is nothing to analyse |
| Planning lag | Allocation sized on last week's offtake | This is how DRP actually works, and it is what creates local stockouts independent of production. Without it every failure would trace back to the plant and the analysis would have one trivial answer |
| Allocation bias by distance | Bhiwandi 1.06 down to Kolkata 0.93 | The depot nearest the plant is the easiest to top up when stock is tight. Creates the distance gradient in service |
| Demand volatility | Log-normal, σ = 0.55 at SKU-depot-week level, plus a 4.5% chance of a bulk lift | B2B offtake at SKU level is lumpy; a fleet customer lifting several weeks of cover at once is normal |
| Minimum stocking lot | 4 pack units, minimum 150 litres | A depot cannot hold a fraction of a drum. Binds only on slow movers, which is what puts extra cover on the tail |
| Unfilled volume valued at | Full gross margin | The aggressive end — it assumes the customer did not simply buy from us a week later. Query 4.6 re-runs the case at partial recapture, and the conclusion survives down to 8.4% |
| Emergency transfer premium | 2.8x planned lane freight | A premium road movement between depots at short notice |
| Aged stock write-off | 1.5% a week on stock above 26 weeks of cover | Lubricants have a 2–4 year shelf life, so this is slow degradation, not spoilage |
| Supplier reliability profiles | Bias and standard deviation per supplier | The hidden truth the analysis is meant to recover. Domestic suppliers usually beat contract lead time slightly; three importers run 3–5 days late with 7–11 day standard deviations |

---

## How the causal chain is built

The generator is a week-by-week simulation, not random flags on a table. That
matters, because it is what lets the SQL trace a service failure back to its
cause:

```
supplier lead-time variance
    → base oil / additive lands after the promised date
    → the plant is short of that material in that week
    → the blending batch runs late and short  (delay_reason = RAW_MATERIAL_SHORT,
                                               causing_po_id = the offending PO)
    → the depot receives less than its planned replenishment
    → the depot runs out
    → a distributor order line cannot be filled  (fail_reason = PLANT_DELAY)
```

Separately, and independently of the plant:

```
replenishment planned on last week's offtake
    → a demand spike this week is not covered
    → the depot runs out even though the plant delivered its plan
    → a distributor order line cannot be filled  (fail_reason = DEPOT_STOCKOUT)
```

Those two chains are why the failure analysis has more than one answer, and why
the misallocation finding in query 5.1 is a real result rather than an artefact.

---

## Reproducing it

`python/generate_data.py` is seeded (`20260906`) so it regenerates the identical
dataset. `python/validate_signal.py` re-derives every number in `RESULTS.md`
directly from the CSVs, independently of the SQL — so if a T-SQL query and the
documentation ever disagree, there is a third opinion to break the tie.

Python is used only to build and check the data. **The analysis is entirely
SQL.**
