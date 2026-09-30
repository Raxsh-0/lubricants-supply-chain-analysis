# Results

Every number below was produced by running the analysis over the dataset in
`data/`. Each figure is listed with the query that produced it.

Dataset: 156 weeks, 4 Sep 2023 – 30 Aug 2026. 466,841 rows across eight tables.
350,422 distributor order lines covering 433.3 million litres ordered and
397.2 million litres delivered.

---

## 1. Service is leaking, and mostly in one place

**Network OTIF: 86.25%** — inside the 85–92% band that published benchmarks
call "good" for industrial goods distribution, and 5.8 points short of the
92% that counts as excellent.

| Metric | Value |
|---|---|
| On time | 88.30% |
| In full | 90.93% |
| OTIF (both) | 86.25% |

Splitting the failure two ways matters, because counting lines and counting
litres give different answers:

| Cause | % of order lines | % of volume lost |
|---|---|---|
| Depot out of stock | 6.42% | 69.4% |
| Transport delay | 4.68% | 0% (arrives, just late) |
| Plant production delay | 1.37% | 15.2% |
| Commercial / credit hold | 1.28% | 15.4% |

**Read:** transport delay is the most frequent failure but costs no volume at
all — the goods arrive, just late. Stock-driven failures are less frequent and
cost 84.6% of the lost litres. If you fix one thing, fix availability.

Service degrades monotonically with distance from the plant:

| Depot | Transit days | OTIF |
|---|---|---|
| Bhiwandi | 1 | 89.50% |
| Ahmedabad | 2 | 87.36% |
| Hyderabad | 3 | 85.76% |
| Gurugram | 4 | 84.94% |
| Chennai | 4 | 84.65% |
| Kolkata | 6 | 82.94% |

A 6.6-point spread from nearest to furthest. Monsoon (June–September) costs a
further 2.2 points of OTIF and 9.4% on freight (Rs 3.34/l against Rs 3.05/l).

*Source: `02_service_leakage.sql`*

---

## 2. The cheapest supplier is the most expensive one

Inbound reliability ranges from **94.2%** OTIF (Raigad Pack Solutions,
domestic, 9-day contract lead time) down to **25.6%** (Crest Performance Chem,
Arabian Synthetics, Orient Grease Chem — all imported).

Raw material shortage caused **30.9% of production batches to run short** and
**95.0% of all lost production volume** (34,813 kL over three years). Every
other cause — changeover, quality hold, maintenance — is rounding error beside
it.

Tracing lost batches back through `causing_po_id` to the supplier:

| Supplier | Material | Production lost |
|---|---|---|
| Crest Performance Chem | Additive (imported) | 9,986 kL |
| Arabian Synthetics | Group III base oil (imported) | 7,335 kL |
| Gulf Star Base Oils | Group II base oil (imported) | 4,347 kL |

**The finding.** Rank suppliers within each material category by price per kg,
then by production lost. In all three categories tested, they are the same
supplier:

| Material | Cheapest per kg | Rank on price | Rank on damage |
|---|---|---|---|
| Additive | Crest Performance Chem, Rs 248.7 | 1 of 5 | 1 of 5 |
| Group II base oil | Gulf Star, Rs 97.4 | 1 of 4 | 1 of 4 |
| Group III base oil | Arabian Synthetics, Rs 120.8 | 1 of 4 | 1 of 4 |

Procurement is ranking on the wrong column. The `true_cost_per_kg` column in
query 3.5 adds the downstream margin lost back onto the purchase price and
reverses the ranking.

*Source: `03_supplier_reliability.sql`*

---

## 3. What the service gap costs

| | Three years | Per year |
|---|---|---|
| Volume ordered but not delivered | 36,145 kL | 12,048 kL |
| Gross margin lost, all causes | Rs 278.75 cr | **Rs 92.92 cr** |
| of which stock-driven (stockout + plant delay) | Rs 237.34 cr | Rs 79.11 cr |
| Total freight | Rs 122.74 cr | Rs 40.91 cr |
| of which emergency transfers | Rs 0.49 cr | Rs 0.16 cr |

Emergency inter-depot transfers cost **Rs 9.60 per litre against Rs 3.08 on a
planned lane — a 3.1x premium.** They are rare (487 lines) so the absolute
number is small, but the ratio is the argument: every emergency movement is a
planning failure being paid for at triple rate.

Cost to serve, per litre delivered, splitting what it costs to move a litre
from what we lose by not having it:

| Depot | Freight Rs/l | Lost margin Rs/l | Cost to serve Rs/l |
|---|---|---|---|
| Kolkata | 5.19 | 7.58 | **12.77** |
| Chennai | 3.87 | 8.22 | 12.09 |
| Gurugram | 4.20 | 7.55 | 11.75 |
| Hyderabad | 2.76 | 7.38 | 10.13 |
| Ahmedabad | 2.59 | 7.02 | 9.61 |
| Bhiwandi | 1.39 | 5.55 | 6.94 |

Kolkata costs 84% more per litre to serve than Bhiwandi. Freight explains 65%
of that Rs 5.83 gap, which is simply geography and cannot be argued with. The
other Rs 2.03 per litre is margin lost to poor availability — and that part is
a planning problem, which can.

*Source: `04_cost_to_serve.sql`*

---

## 4. The headline: the stock was there, in the wrong place

The obvious remedy is to hold more inventory. On the numbers it looks
irresistible: one extra week of cover across the network costs **Rs 36.87 cr**
to buy and **Rs 6.64 cr a year** to carry at an 18% carrying rate, against
**Rs 79.11 cr a year** of margin lost to stock-driven failures. It breaks even
at **8.4% recapture** — recover barely a twelfth of the missed volume and it
pays for itself.

Which should make you suspicious. If it were that easy the business would have
done it.

So test the alternative. For every week in which a depot could not fill an
order, ask whether the other depots held enough of that same SKU, that same
week, to have covered it:

> **97.5% of shortfall events, and 86.6% of the shortfall volume, were
> coverable from stock the network already held elsewhere that week.**

| Depot | Shortfall | Coverable elsewhere |
|---|---|---|
| Kolkata | 3,562 kL | 98.8% |
| Ahmedabad | 2,721 kL | 96.8% |
| Hyderabad | 4,193 kL | 88.8% |
| Chennai | 5,817 kL | 87.4% |
| Gurugram | 7,334 kL | 86.9% |
| Bhiwandi | 6,951 kL | 74.2% |

The replenishment plan corroborates it. Depot-SKU-weeks are **under-supplied
14.1% of the time and over-supplied 12.2% of the time**, with receipts running
at 92.4% of plan overall. A network that misses in both directions in roughly
equal measure does not have a quantity problem. It has a plan built on stale
demand.

**Recommendation:** fix allocation before buying inventory. More stock under
the current rule mostly buys more stock in the wrong depot.

*Source: `05_inventory_allocation.sql`, queries 5.1 and 5.2*

### The tail: tested, and rejected

The other standard remedy is to cut the slow-moving range. The tail looks like
the usual suspect — **39.2% of SKUs generate 5.1% of volume** and carry 2.77
weeks of cover against 1.89 for the A items.

But check what it earns before cutting it:

| Class | SKUs | % of volume | Stock held | Margin per year | Margin per Re 1 of stock |
|---|---|---|---|---|---|
| A | 38 (31.7%) | 79.6% | Rs 55.66 cr | Rs 787.90 cr | Rs 14.2 |
| B | 35 (29.2%) | 15.3% | Rs 11.11 cr | Rs 138.48 cr | Rs 12.5 |
| C | 47 (39.2%) | 5.1% | Rs 4.80 cr | Rs 43.36 cr | **Rs 9.0** |

The tail returns Rs 9 of gross margin per rupee of stock per year. That is
lower than the A items but still strongly positive, and its service is not
worse (C-class OTIF 87.68% against A-class 86.18%). **Do not cut the range.**
Trim cover on specific depot-SKU pairs instead; query 5.7 names the 25 worst.

A negative result, presented as one. Testing the obvious remedy and rejecting
it on the numbers is a better answer than finding what you went looking for.

---

## 5. Capacity runs out at about 1.2x

Plant utilisation runs **79–85% of the 159,000 kL/year nameplate**. Average
requirement is 2,503 kL a week against 3,058 available, so the plant breaches
at **1.22x** current demand.

The depots run out at almost exactly the same point — but two are already over:

| Depot | Capacity kL/wk | Avg | Peak | Weeks over capacity | Breaks at |
|---|---|---|---|---|---|
| Gurugram | 560 | 546 | 806 | **64 of 156 (41%)** | 1.03x |
| Bhiwandi | 780 | 731 | 1,010 | 47 (30%) | 1.07x |
| Chennai | 470 | 437 | 587 | 47 (30%) | 1.08x |
| Hyderabad | 410 | 335 | 482 | 10 (6%) | 1.22x |
| Ahmedabad | 330 | 246 | 349 | 2 (1%) | 1.34x |
| Kolkata | 360 | 251 | 327 | 0 | 1.43x |

At 1.25x demand, four of six depots breach. At 1.5x, all six do.

**Read:** Gurugram is not a future problem, it is a present one — it exceeds
its throughput capacity in two weeks out of five. And because the breach is
concentrated in the festive months rather than spread through the year, the
answer is hired transport and temporary labour, not capex.

*Source: `06_capacity_stress_test.sql`*

---

## The three-sentence version

Service runs at 86.25% OTIF against a 92% benchmark, and the gap costs about
Rs 93 crore of gross margin a year. It looks like an inventory problem, but
86.6% of the volume we failed to deliver was sitting in another depot that same
week — so it is an allocation problem, and buying more stock under the current
replenishment rule would mostly buy more stock in the wrong place. Separately,
procurement is ranking suppliers on price per kg when the cheapest supplier in
every material category is also the one that cost the most production.
