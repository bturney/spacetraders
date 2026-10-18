# Trade and paid-fuel accounting (#786)

The selected private world uses one displayed unit quote per accepted fill, then
applies its existing quantity-dependent stock/price walk. Successive fills may
legitimately differ. IMPORT, EXCHANGE and EXPORT sales must use the displayed
sell quote, not a separate flat percentage of the purchase quote. This repairs
an artificial profit mechanism; it does not calibrate the remaining price model.

Market refueling adds only the requested Ship fuel, capped at tank space. Market
commodity units billed are the upward-rounded number of 100-Ship-fuel units
actually added. The receipt's unit price, quantity and total must agree with the
Agent credit decrease. The retained paid-fuel repair is preserved at this boundary;
controlled worlds retain scheduled, read-independent economic progression.
From-Cargo fuel remains explicitly unsupported, not silently free.

## Independent evidence and chronological separation

Reuse only the authorized, scrubbed October 16 application snapshot and accepted
[practical findings #755](https://github.com/bturney/spacetraders/issues/755#issuecomment-6237436187).
Do not recapture production, request more upstream data or publish raw rows.
Private provenance retains source dates, byte checksums, units and causal joins.

Before implementation, reserve attempts prepared before **2026-10-15 00:00 UTC**
for fit/reference and later attempts for evaluation. Earlier causal quote/credit
observations may support evaluation joins; evaluation must not tune constants.
The earlier #755 full-period aggregate inspection is disclosed: this is a
prospective implementation partition, **not previously unseen evidence**. No
price, payout, production or rival constants are fitted in this slice.

Fuel supporting costs follow the application's charge-at-purchase ownership:
the complete realized refuel charge belongs to the issuing root Intent, original
Fleet Commitment and Strategy Decision Episode. Coverage's fuel is observation-only
spending, not a later trade's expense. Missing monetary evidence or attribution
makes exact Net Earnings unknown, never zero. Credit changes alone are not Net
Earnings. Retained snapshot gaps include own EXPORT sales, from-Cargo fuel,
large holds/Fleets, chart/construction and controlled hidden external activity.

## Bounded actual-runtime observation seam

`NativeBootstrap.configuration/1` accepts optional `proof: "paid_transaction"`
in its explicit isolated manifest; the default remains `"navigation"`. It still
registers, mints and activates normally, then only observes the durable normal
Episode → Commitment → root Intent → successful transaction MutationAttempt.
It neither chooses work nor injects intelligence, policy, receipts or a clock.
Unknown selectors reject before startup. Prepared evidence is private diagnostic
output; never publish it as a fixture. A transaction-only stop reports exact Net
Earnings unknown, not an invented completed-trip outcome.

The existing closed `scripts/native_bootstrap.py` CLI remains its original pinned
navigation profile. The transaction selector is a supporting Elixir observation
seam for separately pinned private fixture orchestration, not authorization to
change its world artifact, budgets or qualification claim.

Use robust directional comparisons under documented conditions. Preserve relevant
declared variations and legitimate downstream divergence. Close or
uncertainty-sensitive results are inconclusive. Historical #652 cashflow/late-price
residuals remain cautions, not numerical tolerances; no full-period or live-ranking
qualification follows from these bounded accounting checks.
