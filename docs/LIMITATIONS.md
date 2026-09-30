# Limitations

Written down so you say them first. Volunteering a limitation reads as
judgement; being caught omitting one reads as something else.

---

**1. The data is synthetic.** No public dataset exists for an internal
lubricants supply chain. Every structural parameter is pinned to a published
figure (see `CALIBRATION.md`), but the rows themselves were generated. The
project is the analysis, not the data collection.

**2. Some effects are in the data by construction.** Suppliers were given
different reliability profiles, and replenishment runs on a planning lag,
because a network with no problems has nothing to analyse. What was *not*
designed is the magnitude of any effect — and one of them (the tail being
profitable) killed a recommendation the project set out expecting to make.

**3. "Coverable elsewhere" is evidence of misallocation, not proof.** Query 5.1
shows the network held enough of the same SKU in the same week to cover 86.6%
of the shortfall volume. It does not prove a better allocation rule would have
captured it — moving stock between depots takes days, and the depot holding the
surplus may have needed it the following week. The honest claim is "the stock
existed", not "the stock was available".

**4. Unfilled volume is valued at full gross margin.** This assumes no
recapture: that the customer did not simply order the same litres a week later.
That is the aggressive end. The business case in query 4.6 is parameterised so
the recapture rate can be set explicitly; the conclusion holds down to 8.4%.

**5. No competitor or price data.** Whether service failures actually pushed
volume to a competitor cannot be tested here. The gross-margin-lost figure is
an upper bound on the commercial damage, not a measured one.

**6. Freight is modelled, not quoted.** Lane rates are derived from published
Indian FTL bands over an assumed load, not from real carrier contracts. The
relative differences between lanes are meaningful; the absolute rupee-per-litre
numbers are indicative.

**7. Weekly grain hides intra-week dynamics.** Stock is tracked weekly, so a
depot that ran out on Wednesday and was restocked on Friday shows as having had
stock all week. This makes the stockout figures conservative — the real service
impact of a stock position is slightly worse than modelled.

**8. 120 SKUs is small.** A real lubricants business would run several hundred.
The range was kept small so the ABC analysis stayed legible. A longer tail would
strengthen the range-rationalisation argument rather than weaken it, so this
limitation cuts against the conclusion drawn, which is the safe direction.

**9. Distributor demand is independent of service.** In reality a distributor
who is let down twice orders less next month. There is no such feedback loop
here, which means the model understates the long-run cost of poor service.

**10. Nothing is inflation-adjusted.** Three years of rupee figures are treated
as comparable. Over 2023–26 that is a real but second-order distortion.
