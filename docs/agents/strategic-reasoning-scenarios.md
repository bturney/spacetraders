# Fleet strategic reasoning — scenario findings and behavioral gaps

> **Status:** Non-normative design evidence for [#502](https://github.com/bturney/spacetraders/issues/502), not a PRD, implementation authorization, additional authority, or change to the active Fleet Strategy.
>
> **Origin:** Operator-guided, one-decision-at-a-time SpaceTraders thought experiments, captured 2026-10-11. Scenario prices, times, yields, rivals, and outcomes below are **invented test inputs**, not live game observations, empirical profitability measurements, or established game mechanics.
>
> **Repository basis:** Current-main source inspection around 2026-10-11 (main at b975110047f4cc04acb6938d7d9cfff374f6eb3d when checked), plus the governing contracts in #502. Re-verify code claims at implementation time.

**Companion design evidence:** [Strategic observability and Operator experience — evidence/gap analysis](strategic-observability-ux-gaps.md) maps the same decision scenarios to existing Mission Control, Grafana, logs, and missing visualization/instrumentation, without adding a new implementation roadmap.

## Purpose and authority

Preserve the behavioral lessons from a hypothetical four-Ship Fleet (two haulers, one miner, one probe) progressing from shared Jump Gate construction to trading, scouting, and a miner-to-market business. The point is to provide falsifiable strategic decision examples for future design and qualification, without creating another competing specification or a standing implementation backlog.

**Authority stays with [#502](https://github.com/bturney/spacetraders/issues/502)** and the repository's ADRs. The relevant contracts are C02 (whole-Fleet allocation), C03 (shared evidence), C05 (adaptive, cost-aware decisions), C06 (bounded coverage and deliberate wait), C08 (complete producer–hauler capability), C10 (causal outcomes and calibration), and C11 (behavioral proof). C01 Standing Authority and Hard Constraints apply throughout. This document proposes no new domain authority, persistent schema, compulsory optimizer, Strategy setting, or additional game mechanic.

**Delivery boundary:** Do not expand the active Gate 2B work in [#684](https://github.com/bturney/spacetraders/issues/684) / [#691](https://github.com/bturney/spacetraders/issues/691) to implement these examples. Select a scenario only when the appropriate #502 gate makes it relevant. [#638](https://github.com/bturney/spacetraders/issues/638) is a separate planning effort for accelerated *actual-bot* simulation; it may eventually supply a way to compare scenarios, but these thought experiments are not that simulator or a qualification receipt.

## Evidence classes and what the simulation can prove

This report distinguishes four kinds of claims:

- **Contract:** Required destination stated by #502 or an ADR. A contract is not evidence of a running implementation.
- **Code observation:** Behavior directly inspected in linked repository source at the stated snapshot. Existence of a module or test is not proof of end-to-end autonomy.
- **Hypothesis:** A plausible but unverified relationship or forecast. It must not authorize a mutation merely because it sounds causally reasonable.
- **Scenario assumption:** Fabricated game state used to exercise a decision rule. The numbers are internally illustrative, not predictive of the live SpaceTraders economy.

Future tests should replace invented facts with a controlled game's authoritative responses. A real behavioral test must activate the Strategy and let the normal Planning/Allocation/Execution pipeline decide; it must not directly script the desired allocations or effects and then declare autonomy proven.

## Decision principles observed

1. **Optimize a Fleet outcome, not local activity.** A positive Trade Margin or a completed mining operation does not establish a better Strategy result. Compare alternatives on the same horizon, with mutually exclusive Ships, capital, capacity, and meaningful uncertainty accounted for.
2. **Preserve ordered Strategic Priorities and Hard Constraints.** Expected future sale proceeds are not realized capital. A quote × units × active Credit Calibration bound must fit after all other admitted, in-flight, and Bounded Unknown exposure, with final authority revalidation (ADR 0013).
3. **Treat Shared World State as revisable.** Other Agents can complete Construction; Markets can reprice or change tradeVolume while a Ship travels. A Plan can become obsolete without its prior decision having been irrational.
4. **Use marginal value for decisions, attributable realized value for learning.** Historical purchase loss is sunk when deciding whether to retain or sell surplus Cargo. Report realized proceeds and Net Earnings separately from the economic value of the next best feasible alternative.
5. **Account for per-transaction depth, not imaginary liquidity.** tradeVolume bounds the next admitted purchase or sale; repeated sales require separate receipts and new evidence. Do not silently fill a full hold at the displayed quote.
6. **Make information decision-relevant.** A probe's Observation Demand should be tied to which feasible Fleet decision new evidence might change, its likely delay, and the supporting cost. A refreshed Listing is not itself a successful Strategic Objective.
7. **An investment thesis can expire without erasing knowledge.** Stop allocating discretionary observation or ship time to a deteriorating opportunity; retain observations and permit re-evaluation on material new evidence. This must not silently withdraw baseline coverage still required by C06, or change Operator-owned Strategy intent.
8. **Keep direct business value separate from speculative effects.** A mined-ore sale can earn revenue independently of an alleged effect on downstream electronics prices. Changes observed after a sale do not prove causality.
9. **Coordinate dependent Ships as one economic contribution.** Extraction, rendezvous, cargo transfer, travel, and sale have shared quantity lineage, bounded dependencies, and a combined economic result; an unrelated hauler remains admissible for independent work.
10. **Truthful unknowns beat false precision.** Where fuel attribution, mining cost, seller depth, yields, market impact, or counterfactual earnings are unobserved, retain an explicit unknown rather than treating a zero or forecast as proven.

These principles are review heuristics for C02/C05/C08/C10, **not** a request for a guaranteed globally optimal planner; #502 explicitly excludes that destination.

## Current implementation: grounded strengths and gaps

| Area | Inspected evidence | Resulting design question |
| --- | --- | --- |
| Whole-Fleet claims, Reservations, dependencies | Fleet Allocation builds portfolios with protected resources and candidate dependencies. #502 C02 requires one coherent decision across all capability owners. | Can a joint producer–hauler contribution compete with independent Ship uses without a second allocation authority? |
| Credit authority | [ADR 0013](../adr/0013-credit-floor-worst-case-exposure.md) bounds every credit-bearing action, including concurrent exposure. | Can the contribution state its peak and sequential credit exposure without counting future sale proceeds early? |
| Ordinary Market candidate economics | [FleetPlanning.candidate_routes](../../lib/spacetraders/fleet_planning.ex) creates buy-at-source/sell-at-destination candidates; maximum_credit_change is observed spread × units; uncertainty records fuel and travel time as unaccounted costs. | How should the comparison include duration, supporting costs, switching, and source goods obtained from production rather than purchase? |
| Market evidence | [Intelligence](../../lib/spacetraders/intelligence.ex) supplies a 30-minute Market Listing freshness budget; Planning checks dependencies and validity. | Will the chosen outcome refresh economically decisive facts at the next irreversible action rather than blindly reuse an aged quote? |
| Resources concurrently with trades | [FleetResources.reconcile](../../lib/spacetraders/fleet_resources.ex) contains an Agent-wide gate, Intents.current(agent) == [], before proposing resource work. | Can an available miner progress while an unrelated hauler has an active Intent, as C02 requires? |
| Cargo producer / transfer | [FleetPlanning.transfer_contributions](../../lib/spacetraders/fleet_planning.ex) creates dependency-backed transfers for Contract and Construction recipients. | Can the same outcome choreography serve a market-sale contribution without copying Contract/Construction ownership into another coordinator? |
| Upstream market effect | [FleetConstruction.market_effect](../../lib/spacetraders/fleet_construction.ex) classifies fresh observed changes and labels the basis observed_listing_change_not_causality; its upstream path depends on supplied hypotheses and outstanding Construction. | Can the system track and reject a speculative effect without conflating it with independently realized trading earnings? |
| Economic evidence | [TradeProgress](../../lib/spacetraders/fleet_allocation/trade_progress.ex) derives Completed Round Trip receipts and attributable supporting charges; unknown gaps remain unknown. | How can a multi-leg producer–hauler outcome inherit the same once-only attribution and durable Strategy Decision Episode provenance? |
| Intelligence | [FleetIntelligence](../../lib/spacetraders/fleet_intelligence.ex) supports durable Market Observation Demands and bounded coverage for known Marketplaces. | How can a strategy economically compare alternative probe positions and stop low-value discretionary refreshing, while still satisfying required coverage? |
| Supply-chain reference | The generated [operation inventory](../../lib/spacetraders/api/operation_inventory.ex) contains GET /market/supply-chain; the bundled [OpenAPI spec](../../priv/spec/SpaceTraders.json) documents exportToImportMap, mapping exported goods to related imports. | Can the planner consume validated reference relationships when relevant, without assuming recipes, conversion yields, price causality, or a runtime consumer not yet established? |

**Important limitations on these observations:** The table does not claim all mentioned gaps are absent across the entire codebase. It identifies behavior not established by the inspected owners and the specific Agent-wide resource gate that is visible in source. Implementation review must repeat this check against its current revision. The simulation did not exercise production, API responses, or the canonical verification gate.

## Scenario catalog: candidate behavioral proof, not fixtures

Each ID describes what a controlled-world test could exercise. Prices and clocks below are only seeds; alternative parameterizations matter more than their exact values. Use the existing [runtime qualification diagnostic](../../test/diagnostics/runtime_qualification.exs) and [stateful game seam](../../test/support/runtime_fleet_game.ex) where applicable instead of adding a second orchestration path.

### SR-01 — Shared Construction progress supersedes a Pledge

- **Setup:** Jump Gate needs 150 material units. The Fleet has delivered 65; a rival Agent delivers 50; our hauler buys 20 more at 1,650 credits per unit, after authoritative remaining-material checks.
- **Change:** During travel, another Agent delivers 28 units. Only 7 are needed when our hauler arrives. An authoritative read confirms the project's terminal state separately from the material tally.
- **Expected decision:** Deliver at most 7; preserve 13 unaccepted Cargo units; update Pledges and release commitments no longer justified by an active Construction outcome. Do not claim the Fleet delivered all 20 or attribute rival progress to us.
- **Proof:** Correct goods/credit/Cargo receipts, authorized limited delivery, shared progress and project completion reconciliation, unaffected Ship continuation, and explanation linked to the original Strategy Decision Episode.
- **Contracts:** C02, C04, C08, C10.

### SR-02 — Surplus Cargo disposition values the Ship's next use

- **Setup:** 13 surplus circuits, acquired earlier at 1,650 each. Fresh local buyer offers 1,400 each (18,200 realized proceeds if accepted); distant quote of 1,900 is 25 minutes old, 70 minutes of travel away, and travel has cost.
- **Competing option:** Selling locally frees the Ship for a plausible independent trade estimated to earn 6,000 net credits during the same broader decision window.
- **Expected decision:** Compare realizable sale receipts, travel/supporting costs, quote age, trade depth, and the Ship's next admissible contribution. Treat the old 21,450-credit inventory cost as historical when choosing what to do *now*. Do not automatically assume the distant quote survives transit or that a no-longer-needed Construction Pledge can keep Cargo tied up.
- **Proof:** Honest inventory ownership/disposition, changed-objective reconciliation, no double sale, expected-versus-realized explanation. A missing general surplus policy should be marked unproven, not guessed from existing inherited-Cargo logic.
- **Contracts:** C02, C05, C08, C10.

### SR-03 — Fleet-wide credit headroom rejects a locally attractive pair

- **Setup:** 346,200 credits; Hard Constraint floor 100,000; illustrative Credit Calibration margin 25%. One home trade costs 65,000 and one frontier trade 150,000 at current quotes.
- **Constraint:** Protected exposure totals 81,250 + 187,500 = 268,750, exceeding available 246,200 headroom by 22,550. The quoted purchases themselves total only 215,000.
- **Expected decision:** Both full purchases cannot be admitted simultaneously. Downsize, defer, or choose a different portfolio, and revalidate against authoritative credits and current quotes before each send. Anticipated sale proceeds cannot cover the difference.
- **Proof:** No oversubscribed Reservation or bypass via concurrent Ships, restart, refuel, or asynchronous completion; explicit rejected alternative and decisive constraint.
- **Contracts:** C01, C02, C04, C05; ADR 0013.

### SR-04 — Probe finds a profitable-looking route that decays before execution

- **Setup:** A probe can reach an unfamiliar frontier Market in 55 minutes. One hauler trades at home; another is held available at an opportunity cost of roughly 9,000 net credits per 90-minute home cycle.
- **Change:** Frontier buyer quotes descend across observations from 2,100 to 1,850 to 1,670. Home cargo costs rise from 1,500 to 1,550; travel and estimated supporting costs remain nonzero.
- **Expected decision:** Fresh positive spread is necessary but not sufficient. Compare estimated Net Earnings *over the whole travel/turnaround horizon*, volatility, quote expiry, capital, and the best alternate use of the Ship. The Fleet may decline the frontier purchase despite a positive spread.
- **Proof:** The probe acquisition and expense are attributable, kept/abandoned optionality is explained, and a declining trade hypothesis cannot force sunk-cost continuation.
- **Contracts:** C02, C03, C05, C06, C10.

### SR-05 — Close a thesis, not baseline coverage

- **Setup:** The frontier's newest observed economics are inferior to repeatable home trade; the probe is at the frontier. Another known Marketplace lacks a detailed Listing.
- **Expected decision:** No further *discretionary* spending solely to support the rejected frontier trade hypothesis. Compare moving the probe to the uncovered Market with other Observation Demands. Retain existing Observations, and re-open the opportunity if later evidence changes its decision value.
- **Boundary:** C06 still requires bounded coverage over every discovered System's known Marketplaces and honest incomplete-coverage handling. A thesis-level stop cannot erase a mandatory open Observation Demand or fabricate a complete negative conclusion. Do not introduce a second schedule of truth.
- **Proof:** Durable due-work timing, attribution and stop reason, no endless low-value scouting, remaining baseline Demands preserved where required.
- **Contracts:** C03, C05, C06, C10.

### SR-06 — Reference supply relationship is not realized market causality

- **Setup:** Industrial buyer pays 260 per COPPER_ORE; 80 units sold for 20,800 gross and an illustrative 17,800 Net Earnings after 3,000 attributable supporting costs. Probe also observes scarce ELECTRONICS.
- **Hypothesis:** Selling ore changes ELECTRONICS price/supply. First verify any claimed export/import relationship against GET /market/supply-chain's actual returned map; do **not** infer a recipe from names. Conversion quantities and the magnitude or timing of market effects are not guaranteed by the relation map.
- **Change:** Electronics price moves after the ore sale but does not reach the threshold required for an economically superior electronics trade.
- **Expected decision:** Retain the profitable standalone ore-sale outcome. Classify the downstream idea as unsupported or still evaluating as appropriate; price movement alone does not prove the sale caused it. No downstream purchase without fresh evidence and a worthwhile bounded outcome.
- **Proof:** Separate direct Net Earnings and hypothetical indirect effects; clear market/evidence provenance; no causality claim by temporal proximity.
- **Contracts:** C03, C05, C08, C10.

### SR-07 — Producer–hauler contribution barely beats independent use

- **Setup:** A miner and Hauler A jointly supply 80 COPPER_ORE to a buyer; Hauler B can execute an independent trade in parallel. Probe observes destination economics. The joint operation takes about 130 minutes.
- **Change:** The buyer's tradeVolume falls to 50. Authoritative sales accept 50 × 310 = 15,500, then 30 × 275 = 8,250 on a separately checked transaction. Supporting credited charges total 4,200; joint contribution Net Earnings = 19,550.
- **Counterfactual:** Over the same modeled horizon, Hauler A could earn approximately 13,000 and the miner 6,000 independently. The joint contribution's **estimated incremental** value is only 550. These independent outcomes are forecasts, not realized transactions. Hauler B's separate 9,000 trade is present on both sides of the comparison and must not be counted as incremental gain from the joint operation.
- **Expected decision:** Report realized joint Net Earnings and estimated counterfactual incremental value separately. Do not turn the route into a standing priority because it earned positive revenue; lower trade depth or uncertain miner yield may erase its marginal advantage.
- **Proof:** Miner acquisition and custody, exact 80-unit transfer, bounded sales, once-only fuel and observation cost attribution, elapsed occupied Ship time, independent Hauler B progress, explicit unknown counterfactual evidence.
- **Contracts:** C02, C05, C08, C10.

### SR-08 — Reject a third cycle or re-source the route

- **Setup:** Successful but marginal ore operation. Buyer now quotes 275 for COPPER_ORE with tradeVolume 30; an alternative asteroid field might reduce mining travel but has unknown yield; another destination might pay more for refined COPPER but has no fresh price.
- **Expected decision:** Compare continuing, adapting the mining source, evaluating a refinery-capable Ship and its actual conversion contract, or returning Ships to independent uses. Acquire only the evidence likely to affect that choice. Re-evaluate or safely unwind the smallest affected commitment subgraph; do not keep production running just to occupy a Ship.
- **Proof:** A bounded, explainable choice based on newly observed evidence; remaining compatible work retained; unproved refinery economics not fabricated.
- **Contracts:** C02, C03, C05, C08, C10.

## Candidate expression using existing domain objects

A useful next design question is whether existing **Candidate Contribution → Fleet Commitment → Strategy Decision Episode** concepts can fully express a multi-Ship economic outcome. **Explore that extension before proposing a new long-lived entity or scheduling authority.**

The candidate would propose an outcome such as **sell up to 80 produced COPPER_ORE units to a currently qualifying buyer**, with:

- **Expected outcome and comparison horizon:** sale quantity/value, attributable spending, anticipated Ship-capable time, costs and uncertainty, and the best feasible competing portfolio. A counterfactual is an estimate, never an actual receipt.
- **Dependencies:** source resource evidence, mining capability and cooldown, acquired Cargo evidence, co-located transfer eligibility and receiving capacity, navigation feasibility, destination Market evidence, and evidence validity at the next irreversible action.
- **Fleet protections:** exclusive Claims on producer and receiving Ship where required, bounded Cargo and credit Reservations, correct dependents and releases, and no duplicate use of extracted inventory. A second unrelated hauler retains independent authority.
- **Execution:** bounded outcomes, not an Operator-issued list of gameplay API calls. A transfer does not become sale revenue; mined material must not be silently priced as if purchased from a Market. Reconcile actual yield and cargo delta before transferring or delivering.
- **Replanning:** adjust quantities at authoritative boundaries; split sales by current tradeVolume and observed repricing; retain compatible independent Ship work; safely unwind when route, recipient, or expected value becomes invalid.
- **Attribution:** the Strategy Decision Episode retains the selected alternatives, decisive reason, original Evidence, realized receipt/charge provenance, outcome classification, and explicitly unknown gaps. Net Earnings are not the same as Agent balance change or a counterfactual opportunity cost.

No precise schema, function signature, optimization algorithm, universal utility score, Strategy knob, or recurring plan lifecycle is specified here. The minimal successful implementation could be a bounded composition of already accepted planner and executor concepts.

## What to measure in a future controlled-game comparison

To avoid false claims of strategic success, capture these in test evidence or a comparable report:

| Dimension | Required distinction |
| --- | --- |
| Economics | Quote/projection vs realized trade receipts, goods acquisition costs, supporting fuel/refuel/jump/observation charges, Net Earnings, Episode Cash Flow, and unknown amounts |
| Quantity | Extracted, held, transferred, bought, sold, accepted, surplus, and per-transaction tradeVolume, each with provenance |
| Capital | Realized credits, protected floor, admitted/reserved/in-flight/Bounded Unknown exposure, release timing; never advance expected sale proceeds |
| Time | Time spent producing, in transit, waiting, scouting, and available for competing Strategic Objectives; compare feasible portfolios over the same horizon |
| Decisions | Alternatives, uncertainty and assumptions, Strategic Priority, binding limitations, acquisition and switching cost, decision/re-evaluation time |
| Evidence | Reference map vs observed Market Listing, observation age, System and Generation scope, causality limitations, and missed/withdrawn Demands |
| Reliability | Actual runtime selection and dispatch, independent Ship continuation, stateful world changes, restart/reconciliation, and truthful Mission Control outcomes |

Relative return per Ship-hour or per constrained credit can help compare options, but it is not a substitute for ordered Strategic Priorities, Hard Constraints, realizable dependencies, or the combined portfolio decision.

## Map to #502 and proof route

| Scenario | Primary #502 obligations | Appropriate future proof |
| --- | --- | --- |
| SR-01, SR-02 | C02, C04, C08, C10 | Shared Construction progress and Cargo disposition under the normal runtime |
| SR-03 | C01, C02, C04, C05 | Concurrent credit admission, quote aging and restart; ADR 0013 invariants |
| SR-04, SR-05 | C02, C03, C05, C06 | Probe/deferred Observation Demand economics and decision-boundary replanning |
| SR-06 | C03, C05, C08, C10 | Actual supply-map interpretation and attribution of direct vs hypothetical effects |
| SR-07, SR-08 | C02, C05, C08, C10 | Producer–hauler graph and independent Ship execution, attributed economics, replan |
| All | C11 | End-to-end controlled game plus relevant deterministic property/contract seams |

**Suggested sequencing, not new tickets:**

1. Preserve the current [Gate 2B qualification](https://github.com/bturney/spacetraders/issues/684) frontier; do not expand its acceptance criteria to include this report.
2. When C02/C05 next come into scope, choose one small scenario whose failure is demonstrated in the *current* normal runtime. In particular, verify the Agent-wide resource gate and whether joint producer–hauler economics can reuse existing Candidate Contributions.
3. When C08/C10 are in scope, extend existing stateful-game and outcome-projection seams to cover multi-Ship quantity lineage and attributable results. Preserve restart/failure proof, not just a scripted happy path.
4. If [#638](https://github.com/bturney/spacetraders/issues/638) later produces an approved accelerated simulator, use these as candidate comparative experiments with controlled conditions and explicit assumptions, not as substitute evidence for #502 gates.

## Open design questions (not approved decisions)

- What is the smallest representation of an **alternative Fleet portfolio over a bounded horizon** that improves on spread × units without requiring a general optimal scheduler?
- How should uncertain Ship time, cooldown, producer yield, and opportunity cost be bounded and calibrated without introducing a fake common unit or moving Operator intent into calibration?
- Which evidence thresholds justify keeping a probe strategically positioned after required baseline coverage is satisfied? How should it stop or re-open a specific economic hypothesis without withdrawing unrelated Observation Demands?
- Can the existing Fleet Commitment dependency representation express multi-Ship production, transfer, sale, and restart-safe partial completion without creating a new execution owner?
- How should resulting Net Earnings attribute genuinely purchased support and unknown resource production costs across one or several Decision Episodes without counting transfers twice?
- How should API supply-chain reference data be acquired, versioned, retained, and invalidated relative to a new Fleet Generation or a changed pinned spec? Its export/import links are not production recipes or causal market-effect guarantees.
- What confidence and material-improvement rule should avoid churning between routes separated by only a small estimated incremental benefit?

## References

- Governing recovery destination: [#502 — Recover and complete reset-to-reset autonomous Fleet Strategy](https://github.com/bturney/spacetraders/issues/502), particularly C02, C03, C05, C06, C08, C10 and C11.
- Active bounded qualification: [#684](https://github.com/bturney/spacetraders/issues/684) and [#691](https://github.com/bturney/spacetraders/issues/691).
- Planned actual-bot accelerated simulation: [#638](https://github.com/bturney/spacetraders/issues/638).
- Governing architecture and spending authority: [ADR 0010](../adr/0010-autonomous-runtime.md), [ADR 0013](../adr/0013-credit-floor-worst-case-exposure.md).
- Terminology and testing: [GLOSSARY](../../GLOSSARY.md), [testing](testing.md), [outcome metrics](outcome-metrics.md).
- Code inspection pointers: [Fleet Planning](../../lib/spacetraders/fleet_planning.ex), [Fleet Allocation](../../lib/spacetraders/fleet_allocation.ex), [Fleet Resources](../../lib/spacetraders/fleet_resources.ex), [Fleet Intelligence](../../lib/spacetraders/fleet_intelligence.ex), [Fleet Construction](../../lib/spacetraders/fleet_construction.ex), [Trade Progress](../../lib/spacetraders/fleet_allocation/trade_progress.ex), [OpenAPI supply chain contract](../../priv/spec/SpaceTraders.json).

**Review goal:** Keep the established #502 destination authoritative. Fix incorrect source readings and scenario assumptions during review. Merge this as contextual, traceable design evidence only; authorize implementation through the already defined bounded gate process.
