"""
Lubricants Distribution Network - synthetic data generator
==========================================================

Builds a 3-year (156-week) operational history for a lubricant blending plant
and its downstream distribution network in India.

WHY SYNTHETIC: no public dataset exists for an internal lubricants supply chain
(inbound base-oil POs, blending batches, depot stock, distributor order lines).
Every parameter below is pinned to a published figure or an industry benchmark;
see docs/CALIBRATION.md for the source of each one.

The generator is a SIMULATION, not a random-flag sprinkler. Causality runs:

    supplier lead-time variance
        -> late base-oil / additive receipt
        -> raw material short at plant
        -> blending batch delayed
        -> depot receives less than planned
        -> depot goes out of stock
        -> distributor order line cannot be filled in full

That chain is what makes the SQL analysis able to trace a service failure at a
distributor back to a specific supplier. Nothing downstream is faked.

Output: 7 CSV files in ../data/, loaded into SQL Server by sql/01_load_data.sql
"""

import numpy as np
import pandas as pd
from datetime import date, timedelta
from pathlib import Path

RNG = np.random.default_rng(20260906)
OUT = Path(__file__).resolve().parent.parent / "data"
OUT.mkdir(parents=True, exist_ok=True)

# ----------------------------------------------------------------------------
# 0. Calendar
# ----------------------------------------------------------------------------
START = date(2023, 9, 4)          # a Monday
N_WEEKS = 156                     # 3 years
WEEKS = [START + timedelta(weeks=w) for w in range(N_WEEKS)]

def week_of(d):
    return (d - START).days // 7

# ----------------------------------------------------------------------------
# 1. SKU master
# ----------------------------------------------------------------------------
# Segment mix follows the Indian market split: automotive end-use ~54%
# (Mordor Intelligence 2026), industrial + grease + metalworking the balance.
SEGMENTS = [
    # code, name,                     share of volume, n_skus
    ("PCMO", "Passenger Car Motor Oil",   0.22, 26),
    ("MCO",  "Motorcycle Oil",            0.12, 16),
    ("HDD",  "Heavy Duty Diesel Engine",  0.20, 20),
    ("IND",  "Industrial Oils",           0.30, 34),
    ("GRE",  "Greases",                   0.08, 12),
    ("MET",  "Metalworking Fluids",       0.08, 12),
]

# Mineral-based products are 67.55% of the Indian market; synthetics the rest.
TIERS = [("SYN", "Full Synthetic", 0.14), ("SEM", "Semi Synthetic", 0.18),
         ("MIN", "Mineral", 0.68)]

PACKS = {
    "PCMO": [(0.9, 0.06), (1.0, 0.09), (3.5, 0.22), (5.0, 0.18), (20.0, 0.15), (208.0, 0.30)],
    "MCO":  [(0.8, 0.18), (1.0, 0.34), (2.5, 0.13), (20.0, 0.15), (208.0, 0.20)],
    "HDD":  [(5.0, 0.10), (7.5, 0.10), (20.0, 0.22), (26.0, 0.08), (208.0, 0.50)],
    "IND":  [(20.0, 0.14), (26.0, 0.06), (208.0, 0.58), (1000.0, 0.22)],
    "GRE":  [(1.0, 0.10), (18.0, 0.34), (20.0, 0.26), (180.0, 0.30)],
    "MET":  [(20.0, 0.20), (208.0, 0.56), (1000.0, 0.24)],
}

# Base oil cost per litre, from OfBusiness India base-oil price bands
# (Gr I Rs 85-95/kg, Gr II Rs 95-110/kg, Gr III Rs 120-140/kg) x 0.87 kg/l density.
BASE_OIL_COST_L = {"I": 78.0, "II": 89.0, "III": 113.0}
GROUP_FOR_TIER = {"SYN": "III", "SEM": "II", "MIN": "I"}

skus = []
sku_id = 0
for seg_code, seg_name, seg_share, n in SEGMENTS:
    for i in range(n):
        sku_id += 1
        tier = RNG.choice([t[0] for t in TIERS], p=[t[2] for t in TIERS])
        if seg_code in ("GRE", "MET"):
            tier = RNG.choice(["SEM", "MIN"], p=[0.25, 0.75])
        group = GROUP_FOR_TIER[tier]
        packs, pw = zip(*PACKS[seg_code])
        pack = float(RNG.choice(packs, p=np.array(pw) / sum(pw)))

        base_cost = BASE_OIL_COST_L[group]
        additive_cost = {"PCMO": 42, "MCO": 38, "HDD": 55, "IND": 26, "GRE": 64, "MET": 34}[seg_code]
        blend_cost = 11.0 + (6.0 if pack <= 5 else 0.0)          # small packs cost more to fill
        pack_cost = {0.8: 14, 0.9: 15, 1.0: 16, 2.5: 9, 3.5: 8, 5.0: 7,
                     7.5: 6, 18.0: 4.2, 20.0: 4.0, 26.0: 3.8, 180.0: 2.4,
                     208.0: 2.2, 1000.0: 1.4}[pack]
        std_cost = round(base_cost + additive_cost + blend_cost + pack_cost, 2)

        margin = {"SYN": RNG.uniform(0.44, 0.52), "SEM": RNG.uniform(0.32, 0.40),
                  "MIN": RNG.uniform(0.24, 0.31)}[tier]
        list_price = round(std_cost / (1 - margin), 2)

        # Volume weight: a Pareto tail, so ~15% of SKUs carry most of the volume.
        vol_weight = float(RNG.pareto(1.25) + 0.10)

        skus.append(dict(
            sku_id=f"SKU{sku_id:04d}",
            sku_name=f"Mobil {seg_name.split()[0]} {tier} {pack:g}L",
            segment_code=seg_code, segment_name=seg_name,
            tier_code=tier,
            base_oil_group=group,
            pack_size_l=pack,
            list_price_inr_per_l=list_price,
            std_cost_inr_per_l=std_cost,
            shelf_life_months=int(RNG.choice([24, 36, 48], p=[0.2, 0.6, 0.2])),
            _seg_share=seg_share, _vol_weight=vol_weight,
        ))

dim_sku = pd.DataFrame(skus)
# Normalise volume weights inside each segment so segment shares hold.
dim_sku["_w"] = dim_sku.groupby("segment_code")["_vol_weight"].transform(lambda s: s / s.sum())
dim_sku["_share"] = dim_sku["_seg_share"] * dim_sku["_w"]
N_SKU = len(dim_sku)

# ----------------------------------------------------------------------------
# 2. Depot master
# ----------------------------------------------------------------------------
# Plant is modelled on ExxonMobil's Isambe (Raigad, Maharashtra) blending plant:
# 159,000 kl/yr nameplate capacity, commissioned 2025 (Rs 900 crore investment).
DEPOTS = [
    # id,      name,        region,   km from plant, transit days, storage kl, throughput kl/wk
    ("DEP-BHW", "Bhiwandi",  "West",     78,  1, 4200, 780),
    ("DEP-GUR", "Gurugram",  "North",  1420,  4, 3300, 560),
    ("DEP-CHN", "Chennai",   "South",  1330,  4, 2900, 470),
    ("DEP-KOL", "Kolkata",   "East",   1960,  6, 2400, 360),
    ("DEP-HYD", "Hyderabad", "South",   710,  3, 2600, 410),
    ("DEP-AMD", "Ahmedabad", "West",    600,  2, 2100, 330),
]
dim_depot = pd.DataFrame(DEPOTS, columns=[
    "depot_id", "depot_name", "region", "distance_km", "std_transit_days",
    "storage_capacity_kl", "throughput_capacity_kl_per_week"])

# Primary freight, plant -> depot, Rs per litre. Derived from published FTL rates
# (Rs 12k-35k for 300-700 km, Rs 28k-70k for 700-1500 km) over a ~18,000 l load.
dim_depot["primary_freight_inr_per_l"] = (0.55 + dim_depot["distance_km"] * 0.00195).round(3)
# Secondary freight, depot -> distributor, is short-haul and roughly flat.
dim_depot["secondary_freight_inr_per_l"] = (0.68 + RNG.uniform(-0.08, 0.12, len(dim_depot))).round(3)

# ----------------------------------------------------------------------------
# 3. Distributor master
# ----------------------------------------------------------------------------
CHANNELS = [("AUTO_RETAIL", 0.42), ("WORKSHOP_OEM", 0.18),
            ("INDUSTRIAL_B2B", 0.28), ("FLEET", 0.12)]
CITY_POOL = {
    "DEP-BHW": ["Mumbai", "Pune", "Nashik", "Thane", "Kolhapur", "Aurangabad"],
    "DEP-GUR": ["Delhi", "Gurugram", "Jaipur", "Ludhiana", "Kanpur", "Lucknow"],
    "DEP-CHN": ["Chennai", "Coimbatore", "Madurai", "Trichy", "Salem"],
    "DEP-KOL": ["Kolkata", "Howrah", "Guwahati", "Patna", "Ranchi", "Bhubaneswar"],
    "DEP-HYD": ["Hyderabad", "Vijayawada", "Vizag", "Warangal", "Nagpur"],
    "DEP-AMD": ["Ahmedabad", "Surat", "Rajkot", "Vadodara", "Indore"],
}
N_DIST = 300
rows = []
depot_ids = dim_depot["depot_id"].tolist()
depot_weight = np.array([0.26, 0.20, 0.16, 0.13, 0.14, 0.11])
for i in range(1, N_DIST + 1):
    dep = RNG.choice(depot_ids, p=depot_weight)
    ch = RNG.choice([c[0] for c in CHANNELS], p=[c[1] for c in CHANNELS])
    tier = RNG.choice(["A", "B", "C"], p=[0.18, 0.34, 0.48])
    rows.append(dict(
        distributor_id=f"DST{i:04d}",
        distributor_name=f"{RNG.choice(['Shree','Sri','New','National','Prime','Bharat','Apex','Gupta','Patel','Verma'])} "
                         f"{RNG.choice(['Lubricants','Auto Traders','Oil Agency','Petro Products','Enterprises'])} {i}",
        depot_id=dep,
        city=RNG.choice(CITY_POOL[dep]),
        channel=ch,
        tier=tier,
        credit_days=int(RNG.choice([21, 30, 45, 60], p=[0.18, 0.42, 0.28, 0.12])),
        onboard_date=(START - timedelta(days=int(RNG.integers(120, 2600)))).isoformat(),
    ))
dim_distributor = pd.DataFrame(rows)
# Hidden traits that drive behaviour but are not exposed as columns.
dist_size = {"A": 3.4, "B": 1.5, "C": 0.65}
dim_distributor["_size"] = dim_distributor["tier"].map(dist_size) * RNG.uniform(0.6, 1.5, N_DIST)
dim_distributor["_credit_risk"] = np.clip(RNG.beta(1.4, 12, N_DIST), 0, 0.5)

# ----------------------------------------------------------------------------
# 4. Supplier master
# ----------------------------------------------------------------------------
# contract_lead_time_days is what the contract says. lt_bias / lt_sigma are the
# hidden truth: how late they actually run and how erratic they are. The whole
# point of the supplier analysis is to recover those from the PO history.
SUPPLIERS = [
    # id, name, material, origin, contract LT, price/kg, lt_bias, lt_sigma, short_ship_rate
    ("SUP-01", "Nandini Base Oils",       "BASE_OIL_G1", "Domestic-Mumbai",   12,  90.0, -1.5,  1.5, 0.010),
    ("SUP-02", "Deccan Petro Refiners",   "BASE_OIL_G1", "Domestic-Chennai",  14,  88.5, -1.2,  2.0, 0.014),
    ("SUP-03", "Konkan Mineral Oils",     "BASE_OIL_G1", "Domestic-Mumbai",   11,  92.5, -1.8,  1.2, 0.008),
    ("SUP-04", "Saurashtra Oils",         "BASE_OIL_G1", "Domestic-Kandla",   13,  89.0, -0.6,  2.4, 0.018),
    ("SUP-05", "Vindhya Petrochem",       "BASE_OIL_G2", "Domestic-Kandla",   19, 101.0, -1.1,  2.1, 0.012),
    ("SUP-06", "Gulf Star Base Oils",     "BASE_OIL_G2", "Import-UAE",        28,  97.5,  3.2,  7.4, 0.036),
    ("SUP-07", "Straits Lube Supply",     "BASE_OIL_G2", "Import-Singapore",  26, 104.0, -0.9,  2.9, 0.015),
    ("SUP-08", "Jamnagar Base Stocks",    "BASE_OIL_G2", "Domestic-Kandla",   17, 106.5, -1.4,  1.8, 0.009),
    ("SUP-09", "Hanwoo Lube Korea",       "BASE_OIL_G3", "Import-Korea",      34, 131.0, -0.5,  3.4, 0.014),
    ("SUP-10", "Arabian Synthetics",      "BASE_OIL_G3", "Import-UAE",        31, 121.5,  4.6, 10.6, 0.052),
    ("SUP-11", "Pacific Group III",       "BASE_OIL_G3", "Import-Singapore",  33, 134.5, -1.0,  2.7, 0.011),
    ("SUP-12", "Elbe Synthetic Stocks",   "BASE_OIL_G3", "Import-Europe",     41, 142.0,  1.2,  4.1, 0.019),
    ("SUP-13", "Aditya Additive Co",      "ADDITIVE",    "Domestic-Mumbai",   21, 268.0, -1.3,  2.2, 0.013),
    ("SUP-14", "Crest Performance Chem",  "ADDITIVE",    "Import-Singapore",  33, 249.0,  4.2,  9.1, 0.044),
    ("SUP-15", "Vanguard Additives",      "ADDITIVE",    "Import-USA",        46, 284.0,  1.0,  4.5, 0.017),
    ("SUP-16", "Sahyadri Speciality",     "ADDITIVE",    "Domestic-Pune",     18, 276.5, -1.6,  1.6, 0.010),
    ("SUP-17", "Vikram Additive Works",   "ADDITIVE",    "Domestic-Kandla",   23, 262.0, -0.4,  3.1, 0.021),
    ("SUP-18", "Raigad Pack Solutions",   "PACKAGING",   "Domestic-Raigad",    9,  62.0, -1.7,  1.0, 0.007),
    ("SUP-19", "Metro Drum & Barrel",     "PACKAGING",   "Domestic-Mumbai",   12,  58.5, -1.2,  1.5, 0.011),
    ("SUP-20", "Polycon Containers",      "PACKAGING",   "Domestic-Silvassa", 10,  60.5, -1.5,  1.2, 0.009),
    ("SUP-21", "Western Thickeners",      "THICKENER",   "Domestic-Vapi",     16, 188.0, -1.1,  1.9, 0.012),
    ("SUP-22", "Orient Grease Chem",      "THICKENER",   "Import-China",      37, 171.5,  3.6,  8.2, 0.041),
    ("SUP-23", "Coastal Solvents",        "SOLVENT",     "Domestic-Mumbai",   11,  74.0, -1.4,  1.4, 0.010),
    ("SUP-24", "Bay Chemicals",           "SOLVENT",     "Import-Singapore",  27,  69.5,  1.9,  5.5, 0.028),
]
dim_supplier = pd.DataFrame(SUPPLIERS, columns=[
    "supplier_id", "supplier_name", "material_type", "origin_hub",
    "contract_lead_time_days", "contract_price_inr_per_kg",
    "_lt_bias", "_lt_sigma", "_short_ship_rate"])

# Which material each SKU consumes, so a supplier failure hits specific SKUs.
MATERIAL_FOR_GROUP = {"I": "BASE_OIL_G1", "II": "BASE_OIL_G2", "III": "BASE_OIL_G3"}

# ----------------------------------------------------------------------------
# 5. Inbound purchase orders
# ----------------------------------------------------------------------------
po_rows = []
po_seq = 0
# Each supplier is ordered from on a fixed cadence.
for _, s in dim_supplier.iterrows():
    cadence = int(RNG.choice([1, 2, 3], p=[0.35, 0.45, 0.20]))   # weeks between POs
    for w in range(0, N_WEEKS, cadence):
        po_seq += 1
        order_dt = WEEKS[w] + timedelta(days=int(RNG.integers(0, 5)))
        promised_dt = order_dt + timedelta(days=int(s["contract_lead_time_days"]))

        # Actual lateness: a supplier's bias plus its own variance. Monsoon and
        # port congestion (Jun-Sep) add delay to imported material only.
        late = RNG.normal(s["_lt_bias"], s["_lt_sigma"])
        if str(s["origin_hub"]).startswith("Import") and order_dt.month in (6, 7, 8, 9):
            late += RNG.gamma(1.6, 2.1)
        late = max(-3.0, late)
        actual_dt = promised_dt + timedelta(days=int(round(late)))

        qty = float(np.round(RNG.uniform(60_000, 240_000) * (1.6 if "BASE_OIL" in s["material_type"] else 0.35), 0))
        short = RNG.random() < s["_short_ship_rate"]
        recv_qty = float(np.round(qty * (RNG.uniform(0.72, 0.94) if short else 1.0), 0))
        qc_hold = int(RNG.choice([0, 0, 0, 0, 1, 2, 3], p=[.68, .09, .07, .05, .05, .04, .02]))

        po_rows.append(dict(
            po_id=f"PO{po_seq:06d}",
            supplier_id=s["supplier_id"],
            material_type=s["material_type"],
            order_date=order_dt.isoformat(),
            promised_date=promised_dt.isoformat(),
            actual_receipt_date=(actual_dt + timedelta(days=qc_hold)).isoformat(),
            ordered_qty_kg=qty,
            received_qty_kg=recv_qty,
            unit_price_inr_per_kg=round(float(s["contract_price_inr_per_kg"]) *
                                        (1 + RNG.normal(0, 0.028)), 2),
            qc_hold_days=qc_hold,
        ))

fact_po = pd.DataFrame(po_rows)
fact_po["po_value_inr"] = (fact_po["received_qty_kg"] * fact_po["unit_price_inr_per_kg"]).round(2)

# ----------------------------------------------------------------------------
# 6. Material availability at the plant, week by week
# ----------------------------------------------------------------------------
# A material is "short" in a given week when the POs that were supposed to have
# landed by then have not. This is the bridge from supplier behaviour to
# production delay - and it is what the SQL joins back together.
materials = sorted(dim_supplier["material_type"].unique())
shortage = {m: np.zeros(N_WEEKS) for m in materials}
blame = {m: [None] * N_WEEKS for m in materials}

po_dates = fact_po.copy()
po_dates["promised_w"] = po_dates["promised_date"].map(lambda d: week_of(date.fromisoformat(d)))
po_dates["actual_w"] = po_dates["actual_receipt_date"].map(lambda d: week_of(date.fromisoformat(d)))

for m in materials:
    sub = po_dates[po_dates["material_type"] == m]
    for _, p in sub.iterrows():
        pw, aw = int(p["promised_w"]), int(p["actual_w"])
        if aw > pw:                       # arrived late -> plant is short in between
            for w in range(max(0, pw), min(N_WEEKS, aw)):
                # severity scales with how much of the week's cover is missing
                shortage[m][w] += 0.55
                if blame[m][w] is None:
                    blame[m][w] = p["po_id"]
        if p["received_qty_kg"] < p["ordered_qty_kg"] * 0.97 and 0 <= aw < N_WEEKS:
            shortage[m][aw] += 0.35
            if blame[m][aw] is None:
                blame[m][aw] = p["po_id"]

# ----------------------------------------------------------------------------
# 7. Demand model
# ----------------------------------------------------------------------------
# Network volume is scaled to a plant running at ~78% of 159,000 kl/yr nameplate.
ANNUAL_KL = 159_000 * 0.78
WEEKLY_L = ANNUAL_KL * 1000 / 52.0

def season_factor(d: date, seg: str) -> float:
    """Indian lubricant demand: pre-monsoon service peak (Apr-May), festive
    restock (Oct-Nov), monsoon trough for construction-linked industrial."""
    m = d.month
    base = {1: 0.97, 2: 1.00, 3: 1.06, 4: 1.14, 5: 1.12, 6: 0.94,
            7: 0.88, 8: 0.90, 9: 1.02, 10: 1.16, 11: 1.10, 12: 0.98}[m]
    if seg in ("IND", "MET"):                     # factory shutdowns in monsoon
        base *= {6: 0.90, 7: 0.86, 8: 0.88}.get(m, 1.02)
    if seg in ("PCMO", "MCO"):                    # festive vehicle servicing
        base *= {10: 1.10, 11: 1.06}.get(m, 1.0)
    if seg == "HDD":                              # harvest + freight season
        base *= {10: 1.08, 11: 1.09, 3: 1.05}.get(m, 1.0)
    return base

TREND = 0.031 / 52.0     # 3.12% CAGR, the published India lubricants growth rate

# --- service-level tuning knobs ---------------------------------------------
# These are set so the simulated network lands inside the published OTIF band
# for industrial / heavy goods distribution (85-92% "good", 92-95% "excellent").
# A network sitting at ~86-87% is realistic: real enough to have a problem worth
# solving, not so broken that the business would already have fixed it.
PLAN_BUFFER = 1.03       # plant produces the replenishment plan + 3%
TARGET_COVER_WEEKS = 2.1 # depot replenishment target, in weeks of cover
DEMAND_CV = 0.55         # week-to-week volatility of SKU-depot offtake
BULK_ORDER_P = 0.045     # chance a week contains a bulk lift
CREDIT_HOLD_K = 0.13     # scales each distributor's hidden credit-risk trait
LATE_BASE = 0.016        # base probability a delivery misses its promised date
LATE_PER_DAY = 0.0085    # extra late risk per day of standard transit
MIN_LOT_PACKS = 4        # minimum stocking lot at a depot, in pack units

# depot share of network volume
depot_share = dict(zip(dim_depot["depot_id"], [0.27, 0.21, 0.16, 0.12, 0.14, 0.10]))

# Which SKUs each depot stocks. Deliberately over-broad: every depot carries
# almost the whole range, which is the practice the assortment analysis attacks.
sku_ids = dim_sku["sku_id"].tolist()
sku_share = dict(zip(dim_sku["sku_id"], dim_sku["_share"]))
stock_list = {}
for dep in depot_ids:
    keep = [s for s in sku_ids if RNG.random() < 0.88]
    stock_list[dep] = set(keep)

# ----------------------------------------------------------------------------
# 8. Weekly simulation: production -> depot stock -> order fulfilment
# ----------------------------------------------------------------------------
sku_meta = dim_sku.set_index("sku_id")[
    ["base_oil_group", "segment_code", "list_price_inr_per_l", "std_cost_inr_per_l", "pack_size_l"]].to_dict("index")
depot_meta = dim_depot.set_index("depot_id").to_dict("index")

batch_rows, stock_rows, order_rows = [], [], []
batch_seq = order_seq = 0

# opening stock ~ 3.5 weeks of cover
stock = {(d, s): WEEKLY_L * depot_share[d] * sku_share[s] * 3.5
         for d in depot_ids for s in stock_list[d]}

# Allocation of finished stock to depots is planned on LAST week's offtake, not
# this week's actual demand - which is how real DRP works, and which is why a
# depot can go short even in a week when the plant produced everything it
# promised. Without this lag every stockout would trace back to the plant, and
# the "where is the leak" analysis would have only one answer.
prev_demand = {}
# Remote depots are chronically under-allocated when stock is tight: the closest
# depot is the easiest one to top up.
ALLOC_BIAS = {"DEP-BHW": 1.06, "DEP-AMD": 1.02, "DEP-HYD": 0.99,
              "DEP-GUR": 0.97, "DEP-CHN": 0.96, "DEP-KOL": 0.93}

PLANT_WEEKLY_CAP = 159_000 * 1000 / 52.0     # nameplate, litres per week

for w, wk in enumerate(WEEKS):
    # ---- 8a. demand for the week -------------------------------------------
    week_demand = {}
    for dep in depot_ids:
        for s in stock_list[dep]:
            seg = sku_meta[s]["segment_code"]
            base = WEEKLY_L * depot_share[dep] * sku_share[s]
            d = base * season_factor(wk, seg) * (1 + TREND) ** w * RNG.lognormal(0, DEMAND_CV)
            # B2B offtake is lumpy: a fleet or industrial customer occasionally
            # lifts several weeks of cover in one go.
            if RNG.random() < BULK_ORDER_P:
                d *= RNG.uniform(1.9, 3.6)
            week_demand[(dep, s)] = d

    # ---- 8b. replenishment plan (DRP) --------------------------------------
    # Each depot is replenished up to a target weeks-of-cover, sized on LAST
    # week's offtake, not this week's actual demand. That planning lag is the
    # reason a depot can go short even when the plant delivered its whole plan.
    need = {}
    for dep in depot_ids:
        for s in stock_list[dep]:
            fcst = prev_demand.get((dep, s), week_demand[(dep, s)]) * ALLOC_BIAS[dep]
            target = fcst * TARGET_COVER_WEEKS
            need[(dep, s)] = max(0.0, target - stock[(dep, s)])

    # ---- 8c. production -----------------------------------------------------
    planned_total = sum(need.values()) * PLAN_BUFFER
    scale = min(1.0, PLANT_WEEKLY_CAP / planned_total) if planned_total > 0 else 1.0

    produced = {}
    rm_short_sku = set()          # SKUs whose batch was hit by a raw-material shortage
    for s in sku_ids:
        planned = sum(need.get((dep, s), 0.0) for dep in depot_ids) * PLAN_BUFFER * scale
        if planned <= 0:
            continue
        grp = sku_meta[s]["base_oil_group"]
        mat = MATERIAL_FOR_GROUP[grp]

        # Does a raw-material shortage bite this SKU this week?
        sev = shortage[mat][w] + 0.45 * shortage["ADDITIVE"][w]
        if sku_meta[s]["segment_code"] == "GRE":
            sev += 0.5 * shortage["THICKENER"][w]
        if sku_meta[s]["segment_code"] == "MET":
            sev += 0.4 * shortage["SOLVENT"][w]

        reason, delay_days, culprit_po = "NONE", 0, None
        yield_pct = 1.0
        if sev > 0.32 and RNG.random() < min(0.80, sev * 0.62):
            reason = "RAW_MATERIAL_SHORT"
            delay_days = int(np.clip(RNG.gamma(2.0, 1.9 * sev), 1, 21))
            yield_pct = float(np.clip(1 - RNG.uniform(0.10, 0.42) * min(sev, 1.8), 0.35, 0.95))
            culprit_po = blame[mat][w] or blame["ADDITIVE"][w]
            rm_short_sku.add(s)
        elif RNG.random() < 0.030:
            reason = "CHANGEOVER"
            delay_days = int(RNG.integers(1, 4)); yield_pct = RNG.uniform(0.88, 0.99)
        elif RNG.random() < 0.017:
            reason = "QUALITY_HOLD"
            delay_days = int(RNG.integers(2, 9)); yield_pct = RNG.uniform(0.70, 0.95)
        elif RNG.random() < 0.011:
            reason = "MAINTENANCE"
            delay_days = int(RNG.integers(1, 6)); yield_pct = RNG.uniform(0.80, 0.97)

        actual = planned * yield_pct
        produced[s] = actual
        batch_seq += 1
        p_start = wk + timedelta(days=int(RNG.integers(0, 5)))
        batch_rows.append(dict(
            batch_id=f"BT{batch_seq:06d}",
            sku_id=s,
            plant_id="PLT-ISB",
            week_start_date=wk.isoformat(),
            planned_start_date=p_start.isoformat(),
            actual_start_date=(p_start + timedelta(days=delay_days)).isoformat(),
            planned_qty_l=round(planned, 1),
            actual_qty_l=round(actual, 1),
            delay_days=delay_days,
            delay_reason=reason,
            causing_po_id=culprit_po,
        ))

    # ---- 8c. allocate production to depots, then fulfil orders --------------
    for dep in depot_ids:
        dmeta = depot_meta[dep]
        transit = int(dmeta["std_transit_days"])
        for s in stock_list[dep]:
            demand = week_demand[(dep, s)]
            # What this depot was promised, and what the plant could actually
            # give it. When production is cut, every depot is short pro rata.
            planned_receipt = need[(dep, s)] * PLAN_BUFFER * scale
            need_total_s = sum(need.get((d2, s), 0.0) for d2 in depot_ids)
            share = (need[(dep, s)] / need_total_s) if need_total_s > 0 else 0.0
            actual_receipt = produced.get(s, 0.0) * share

            opening = stock[(dep, s)]
            # A depot cannot hold a fraction of a pack lot. Every stocked
            # SKU is replenished to at least one minimum lot, however slowly
            # it sells - which is exactly what strands cash in the long tail.
            # The floor only ever binds on slow movers - a fast mover's weekly
            # offtake is far larger than one lot - so it strands cash in the
            # tail without rescuing the A items from genuine stockouts.
            min_lot = max(150.0, sku_meta[s]["pack_size_l"] * MIN_LOT_PACKS)
            if demand < min_lot and opening + actual_receipt < min_lot:
                actual_receipt = min_lot - opening
            available = opening + actual_receipt

            # split the week's demand into order lines
            n_lines = max(1, int(RNG.poisson(max(0.6, demand / 1400))))
            line_qty = RNG.dirichlet(np.ones(n_lines) * 2.2) * demand

            dispatched = 0.0
            dep_dists = dim_distributor[dim_distributor["depot_id"] == dep]
            for q in line_qty:
                if q < 1:
                    continue
                order_seq += 1
                dist = dep_dists.sample(1, random_state=int(RNG.integers(0, 1_000_000))).iloc[0]
                order_dt = wk + timedelta(days=int(RNG.integers(0, 7)))
                promised_dt = order_dt + timedelta(days=transit + 1)

                ordered = float(np.round(q, 1))
                fail = "NONE"

                # credit hold: driven by the distributor's hidden risk trait
                if RNG.random() < dist["_credit_risk"] * CREDIT_HOLD_K:
                    delivered = 0.0
                    fail = "CREDIT_HOLD"
                else:
                    can_ship = max(0.0, available - dispatched)
                    if can_ship >= ordered:
                        delivered = ordered
                    else:
                        delivered = float(np.round(can_ship, 1))
                        # Attribute the shortfall. It is only the plant's fault
                        # when this SKU's batch was actually cut by a raw
                        # material shortage AND the depot got materially less
                        # than it was promised. Everything else is local
                        # replenishment planning at the depot.
                        upstream = (s in rm_short_sku
                                    and planned_receipt > 0
                                    and actual_receipt < planned_receipt * 0.80)
                        fail = "PLANT_DELAY" if upstream else "DEPOT_STOCKOUT"
                    dispatched += delivered

                # on-time: lane reliability, worse in monsoon and on long lanes
                late_p = LATE_BASE + dmeta["std_transit_days"] * LATE_PER_DAY
                if order_dt.month in (6, 7, 8, 9):
                    late_p += 0.026           # monsoon
                if order_dt.month in (10, 11):
                    late_p += 0.012           # festive congestion
                late_days = 0
                if delivered > 0 and RNG.random() < late_p:
                    late_days = int(np.clip(RNG.gamma(1.7, 1.5), 1, 14))
                    if fail == "NONE":
                        fail = "TRANSPORT_DELAY"

                delivered_dt = promised_dt + timedelta(days=late_days) if delivered > 0 else None

                # emergency inter-depot transfer to rescue a big stockout
                emergency = 0
                if fail in ("DEPOT_STOCKOUT", "PLANT_DELAY") and ordered - delivered > 900 and RNG.random() < 0.22:
                    emergency = 1

                freight = (dmeta["primary_freight_inr_per_l"] + dmeta["secondary_freight_inr_per_l"])
                if emergency:
                    freight *= 2.8            # premium road movement between depots
                if order_dt.month in (6, 7, 8, 9):
                    freight *= 1.09           # monsoon rate hardening

                on_time = 1 if (delivered > 0 and late_days == 0) else 0
                in_full = 1 if (delivered >= ordered - 0.5) else 0

                order_rows.append(dict(
                    order_line_id=f"OL{order_seq:08d}",
                    order_date=order_dt.isoformat(),
                    distributor_id=dist["distributor_id"],
                    depot_id=dep,
                    sku_id=s,
                    ordered_qty_l=ordered,
                    delivered_qty_l=round(delivered, 1),
                    promised_delivery_date=promised_dt.isoformat(),
                    actual_delivery_date=delivered_dt.isoformat() if delivered_dt else None,
                    on_time_flag=on_time,
                    in_full_flag=in_full,
                    fail_reason=fail,
                    is_emergency_transfer=emergency,
                    freight_cost_inr=round(delivered * freight, 2),
                ))

            closing = max(0.0, available - dispatched)
            # Stock sitting on more than six months of cover ages towards its
            # shelf life and is written off. Recorded explicitly so the stock
            # ledger balances: opening + receipts - dispatches - writeoff = closing.
            writeoff = 0.0
            if closing > demand * 26:
                writeoff = round(closing * 0.015, 1)
                closing -= writeoff
            stockout_days = 0 if closing > demand * 0.12 else int(RNG.integers(1, 8))

            stock_rows.append(dict(
                depot_id=dep, sku_id=s, week_start_date=wk.isoformat(),
                opening_stock_l=round(opening, 1),
                receipts_l=round(actual_receipt, 1),
                planned_receipts_l=round(planned_receipt, 1),
                dispatches_l=round(dispatched, 1),
                writeoff_l=writeoff,
                closing_stock_l=round(closing, 1),
                stockout_days=stockout_days,
            ))
            stock[(dep, s)] = closing

    prev_demand = dict(week_demand)

# ----------------------------------------------------------------------------
# 9. Write CSVs
# ----------------------------------------------------------------------------
fact_batch = pd.DataFrame(batch_rows)
fact_stock = pd.DataFrame(stock_rows)
fact_order = pd.DataFrame(order_rows)

dim_sku.drop(columns=[c for c in dim_sku.columns if c.startswith("_")]).to_csv(OUT / "dim_sku.csv", index=False)
dim_depot.to_csv(OUT / "dim_depot.csv", index=False)
dim_distributor.drop(columns=[c for c in dim_distributor.columns if c.startswith("_")]).to_csv(
    OUT / "dim_distributor.csv", index=False)
dim_supplier.drop(columns=[c for c in dim_supplier.columns if c.startswith("_")]).to_csv(
    OUT / "dim_supplier.csv", index=False)
fact_po.to_csv(OUT / "fact_inbound_po.csv", index=False)
fact_batch.to_csv(OUT / "fact_production_batch.csv", index=False)
fact_stock.to_csv(OUT / "fact_depot_stock_weekly.csv", index=False)
fact_order.to_csv(OUT / "fact_order_line.csv", index=False)

print(f"dim_sku                  {len(dim_sku):>9,}")
print(f"dim_depot                {len(dim_depot):>9,}")
print(f"dim_distributor          {len(dim_distributor):>9,}")
print(f"dim_supplier             {len(dim_supplier):>9,}")
print(f"fact_inbound_po          {len(fact_po):>9,}")
print(f"fact_production_batch    {len(fact_batch):>9,}")
print(f"fact_depot_stock_weekly  {len(fact_stock):>9,}")
print(f"fact_order_line          {len(fact_order):>9,}")
print(f"TOTAL                    {len(dim_sku)+len(dim_depot)+len(dim_distributor)+len(dim_supplier)+len(fact_po)+len(fact_batch)+len(fact_stock)+len(fact_order):>9,}")
print()
print("OTIF          ", round(100 * ((fact_order.on_time_flag == 1) & (fact_order.in_full_flag == 1)).mean(), 2))
print("fail mix      ", fact_order.fail_reason.value_counts(normalize=True).round(4).to_dict())
print("volume (M l)  ", round(fact_order.delivered_qty_l.sum() / 1e6, 1))
