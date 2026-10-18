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

The bounded offline reconciliation produced these source-free findings:

| Successful attempts | Fit: October 11–14 | Evaluation: October 15–16 | Reconciled rule |
| --- | ---: | ---: | --- |
| Cargo buys | 883 | 395 | Quote × billed units, realized charge and credits |
| Cargo sells | 882 | 395 | Selected sale quote × filled units equals credit increase |
| Paid refuels | 1,033 | 468 | Ceiling(requested fuel / 100), charge and bound credits |

All 1,501 refuels have one charge Realization and an explicit issuing-Intent join;
171 belong to coverage work, not subsequent trades. Requested Ship fuel spans
62–400 units; only two requests are exact multiples of 100. The refuel check uses
the explicit pre-credit observation, not a missing selected-action balance.
Own cargo fills span 6–40 units. Composite/time-matched Market transactions
corroborate 1,277 buys and 1,271 sells; seven unmatched attempts remain gaps,
not invented transaction IDs. Own sale roles are IMPORT and EXCHANGE only:
EXPORT sale consistency is a simulator contract regression, not independently
observed own-sale coverage. Snapshot-wide Net Earnings was not reconstructed.

Bounded real-HTTP regressions check all three sale roles, 6/34-unit successive
fills, paid-fuel 1/99/100/101-unit boundaries, tank clamping, credits and rejected
requests. Existing scheduled-world checks still cover read-independent economics
and Arrival **10** → economics **20** → rival **30** ordering. Boundary cases outside
the retained observations are contract checks, not new live measurements.

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
