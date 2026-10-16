# Fleet plan health: can existing expectation evidence support it?

**Research for [#748](https://github.com/bturney/spacetraders/issues/748), under [Operator Experience Recovery #741](https://github.com/bturney/spacetraders/issues/741). Inspected 2026-10-16.** Read-only: source at upstream main `ca37d98`, which is the deployed image per the [prior evidence note](operator-experience-evidence.md). Also used live Prometheus (`job="spacetraders"`) and Loki (`{service_name="spacetraders-web-1"}`) through Grafana. No database access, gameplay, Strategy edit, or deploy.

## Answer

1. **A forecast-trend status ("on plan against a forecast") is not supported.** No Fleet-level plan figure exists. The active objective is a continuous "Grow credits" with no target. Episode expectations carry no time dimension and mix credit and non-credit units. The engine's only earning-rate forecast (`planned_rate`) is discarded for the work it actually selects.
2. **A condition-based plan-health status is supported today, without new evidence.** Green, yellow and red can be composed from facts that are already durable or projected: structural stall, Shortfall, Capacity Deferral, Neutral Wait, overdue Demands, Pricing-model Breach, evidence freshness, and realized Net Earnings. Unknown stays a distinct state, not a colour.
3. **Smallest addition for a forecast trend:** keep each selected Market trade Commitment's existing `planned_rate` (estimated net credits per Ship-hour) and its evidence in the publishing Episode's `expectations`. Owner: `FleetAllocation.MarketDomain`. Then `MissionControl` can compare the expected Fleet rate (the sum over live trade Commitments) against the realized Net Earnings rate from `TradeProgress.for_generation` over the same window. This needs no new table.

## 1. Inventory of expectation evidence

| Evidence | What it holds (source) | Window-aggregable? Comparable to realized? | How incomplete/unknown surfaces |
| --- | --- | --- | --- |
| **Episode expectations** | Market: `%{domain, expected_value: sum of selected expected_value, commitment_count}` ([market_domain.ex:278-282][md-exp]). A Commitment's `expected_value` is `maximum_credit_change` (spread × max units), falling back to `decision_value` ([fleet_allocation.ex:2126-2136][fa-ev]). Trade value is **gross**, with `unaccounted_costs: [:fuel, :travel_time]` ([fleet_planning.ex:2749-2753, 2796][fp-trade]). Intelligence/coverage value is a heuristic `decision_value` net of API/ship-time cost ([fleet_planning.ex:2170-2214][fp-intel]), **not credits**. | **No.** There is no expected duration or completion time, so no expected credits/hour. The Episode sum mixes credit and non-credit units. The walkthrough's "Expected value 609.1989…" can only be a non-trade decision value, because integer prices × integer units give an integer. **Per trade, yes:** a trade Commitment's `expected_value` and its trip's `trade_margin` share a gross basis (both exclude fuel), joined by `commitment_id` ([trade_progress.ex:461-482][tp-trip]). | Classification: `still_evaluating` / `realized` / `partially_realized` / `superseded` / `reset_censored` ([strategy_decision_episode.ex:38-42, 60-62][sde]). Set from receipts by `TradeProgress.classification` ([trade_progress.ex:319-325][tp-class]); a missing receipt is `"unknown"`, never zero ([trade_progress.ex:13-15][tp-doc]). |
| **Market work rate (`planned_rate`)** | Net credits per Ship-hour: `3600 × (gross − max supporting cost) / longest occupied seconds`, from comparable completed trips of the same Generation. Model `market-observed-whole-work-v1`; deliberately conservative; "a forecast, not … a realized-rate comparator" ([market_work_rate.ex:1-18, 105-134][mwr]). | **Would be**, being a rate on the same net basis as trip Net Earnings. But **selected Commitments drop it**: `insert_commitment` persists only `expected_value` ([fleet_allocation.ex:1725-1738][fa-insert]). It survives only in rejected `alternatives`, which `UnmetWork` reads for Capacity Investment ([fleet_allocation.ex:100-104][fa-rate-doc], [unmet_work.ex:48-49][uw]). | `planned_rate: nil`, `state: :unknown`, `reason: :missing_comparable_whole_work_or_supporting_evidence` ([market_work_rate.ex:127-134][mwr]). A first trip on a new route, Good, quantity or Ship profile is always unknown. |
| **Credit Calibration** | Versioned worst-case **spend** margin (start 25%, floor 10%), plus Realizations (quoted versus realized charge) and Shortfalls ([credit_calibration.ex:1-15][cc]). | **No.** It bounds what a spend can cost and does not forecast outcomes. Realizations feed realized supporting cost. | A Pricing-model Breach widens the margin and raises Degraded Attention ([credit_calibration.ex:408-422][cc-breach]). That is a setback signal, not a forecast. |
| **Strategic Objective evaluation** | Kinds: attain (`target`, `expected_seconds_to_target`), maintain (`target`, `required_margin`), and continuous (`change / elapsed × horizon`, no target) ([objective_evaluation.ex:99-141][oe]). Presets define "Grow credits" as **continuous** with no target ([fleet_strategy.ex:37-48][presets]). The walkthrough's "Observed net change … Feasibility is unknown" is the fallback label that only the continuous "Grow credits" objective produces ([mission_control.ex:1097-1120][mc-obs], [mission_control_live.ex:659-661][mcl-label]). So the deployed Revision has that objective, and no valid persisted evaluation is shown. | An attain objective could act as a plan (a target and an ETA). The deployed continuous objective has nothing to be "on" except its own past rate. **No autonomous producer of evaluations exists:** `publish_portfolio` passes the domain decision to `record_objective_evaluations` ([fleet_allocation.ex:263-268][fa-pub]), but Market decisions carry no `objective_evaluations` ([market_domain.ex:270-289][md-exp]), so it is a no-op ([fleet_generation.ex:748-783][fg-rec]). The only other path is `rank_plans`, used by Emergency Stop resume ([fleet_allocation.ex:2594-2612][fa-rank]). | Mission Control falls back to the observed change since Generation start, but only with valid credit evidence at most 300 s old. Otherwise `{:error, :unknown}` → "Outcome status unknown" ([mission_control.ex:1052-1122][mc-obs], [mission_control_live.ex:555-556][mcl-health]). **Objective-infeasible Attention ([operator_conditions.ex:72-99][oc-obj]) therefore cannot fire on the autonomous path.** |
| **Generation Horizon** | Seconds to the announced next reset, capped by a 48 h calibration window. Needs a `server:status` observation from this Generation, at most 30 s old ([generation_horizon.ex:18-62][gh], [ship_acquisition_calibration.ex:12][sac]). | **Denominator only.** It turns a rate into "by reset" but is not itself an expectation. It is computed on demand for Capacity Investment, so a glance projection would usually see `:stale_reset_evidence`. | `status: :unknown` with a reason: `missing_reset_evidence`, `stale_reset_evidence`, `generation_not_current`, and others ([generation_horizon.ex:20-60][gh]). Never assumed unbounded. |
| **Outcomes metrics** | Realized only: `agent_credits` and the previous credit pair (net credits/h over the last observation interval), and gross receipt counters by Intent type ([outcome-metrics.md:28-39, 102-118][om]). No expectation series exists. | Realized side: yes, per window. Expected side: none. | Family epochs; freshness 0–120 s with `up==1`, else a gap ([outcome-metrics.md:94-100][om]). |
| **Realized comparators (for reference)** | `TradeProgress.for_generation`: per-trip `trade_margin` and `net_earnings`, `sale_finished_at`, and `observed_occupied_seconds`, plus Generation `episode_cash_flow` and `observation_only_spending` ([trade_progress.ex:60-125, 461-482][tp-build]). Generation `starting_credits` and `last_observed_credits` ([fleet_generation.ex:797-848][fg-obs]). | **Yes.** Trips carry timestamps, so Net Earnings per trailing window is a pure read projection. Balance delta is not Net Earnings: cargo float makes it noisy (see the live data below). | Unknown supporting charges make `net_earnings` `"unknown"` with named gaps ([trade_progress.ex:105-117][tp-build]). |

**Live realized data** (Prometheus `spacetraders_outcome_agent_credits{job="spacetraders"}`, 6 h steps from 2026-10-12T16:54Z to 2026-10-16T16:54Z):

- Balance went from 1,909,102 to 2,897,582, about **+10.3k credits/h**.
- 2 of the 16 six-hour windows were negative (−3,499 and −14,619); the range was −14.6k to +121k.

A balance-delta threshold would therefore flicker yellow while the Fleet is healthy. Use receipt-backed Net Earnings instead.

## 2. Detectable setbacks and blockers → proposed mapping

The precedence cascade already exists as Mission Control's `health_label` ([mission_control_live.ex:523-574][mcl-health]) and `MarketDisposition.state` ([market_disposition.ex:51-69][disp]). Plan health is mostly a **re-labelling and re-grouping** of these facts. The one change is that the conditions branch ("Needs Operator attention", [mission_control_live.ex:535][mcl-health]) must stop meaning "needs you" (see the #742 contradiction 1).

| Signal | Detectable now from | Proposed | Why / release shown |
| --- | --- | --- | --- |
| Structural stall (Degraded Operation) | Open `structural_stall` Episode → `state: :stalled`, the only non-healthy disposition ([market_disposition.ex:11-16, 83-92][disp]). Logged with `stall_reason` ([observability.md:84-109][obs]). | **Red** | Allocation cannot progress. Release text comes from `StructuralStall.release_condition` ([structural_stall.ex:117-131][ss]). |
| Open Shortfall (spending paused) | `CreditCalibration.oldest_open_shortfall` → `:spending_paused`, with balance, floor and release predicate ([market_disposition.ex:162-195][disp]). DB only: not logged, no metric. | **Red** while open | It pauses every new credit-bearing action, so trading cannot buy. It self-releases on a balance at or above the floor. |
| Not Strategy-capable / no Generation / Server Reset transition | `health_label` lifecycle branches ([mission_control_live.ex:532-546][mcl-health]) | **Red**, or a lifecycle state | No Strategy progress is possible. Emergency Stop is Operator-initiated: show "Stopped", not a colour. |
| Pricing-model Breach (after release) | Calibration version widened, with Degraded Attention ([credit_calibration.ex:408-422][cc-breach]) | **Yellow** | Spend estimates were wrong once and the model has corrected itself. |
| Capacity Deferral | `FleetCapacity.disposition("get-market")` is non-`:proceed` → `:capacity_deferred` ([market_disposition.ex:199-204][disp]). The glossary says it is temporary. `spacetraders_intent_capacity_deferrals_total` currently has **no series** (unknown, not zero). | **Yellow** | Throttled, not blocked. Show `retry_at`. |
| Overdue Observation Demands (not stalled) | `overdue_demand_count` ([market_disposition.ex:49, 76][disp]). Overdue Demands alone never make a stall ([observability.md:116][obs]). | **Yellow** | Old prices: decisions continue on aging evidence. |
| Objective "Falling behind" (observed change < 0 since Generation start) | `objective_status` ([mission_control_live.ex:676-684][mcl-label]) | **Yellow** | The figure is cumulative and lags. Prefer a trailing-window Net Earnings (below). |
| Busy but not earning | `:busy_trade` plus no Completed Round Trip, or negative Net Earnings, in a trailing window from `TradeProgress.for_generation` | **Yellow** | Pure projection, but **the window length and threshold are undecided**. The walkthrough's real case was −40k over 8 h with Intents running. |
| Trades realizing below expectation | Trade Commitment `expected_value` versus the trip's `trade_margin` (same gross basis) | **Yellow** (optional) | Answers J3's "expected +609, got +571". It needs a tolerance and excludes non-trade Commitments. |
| Neutral Wait | Pointer `:neutral_wait`, with `next_observation_at` ([market_disposition.ex:208-224][disp]) | **Green** ("waiting on purpose") | A deliberate result; the glossary says it never raises Attention. |
| Stale or absent headline evidence | Objective evidence older than 300 s ([mission_control.ex:1077-1081][mc-obs]); Agent/Ship read errors ([mission_control_live.ex:549-550][mcl-health]); outcome epoch older than 120 s; Stale Agent | **Unknown** (no colour): "as of T, because R" | Absent or stale evidence is never health or zero (#741 truth rule). If the Operator insists on exactly three colours, decide explicitly whether unknown folds into yellow. Never fold it into green. |

**Nothing maps to "needs the Operator".** Every row's release is reconciliation, a balance recovery, a capacity retry, or an observation. The remaining Intervention keys (`replacement-authority`, `replacement-symbols`, `server-reset-replacement`, [fleet_generation.ex:227-252][fg-int]) are lifecycle states for the #742 contradiction-1 decision; they are not plan-health inputs.

**Retained telemetry, 7 days to 2026-10-16T16:54Z:**

- 34,349 "Fleet Allocation Market domain decision" log lines.
- **0 lines** matching `stall_reason|Shortfall|spending_paused|capacity_deferred|neutral_wait|Degraded Operation|pricing-model`.
- Market decision results: `retained` ≈ 29,967, `published` ≈ 4,358 (`trade_selected` 1,927, `coverage_selected` 2,405, `trade_and_coverage_selected` 26), `released` 7.

Red therefore has not occurred in the retained window. Shortfalls and Neutral Waits are not logged, so their absence from logs is **unknown**, not proven.

## 3. Simplest truthful status, and the smallest addition

**Now (no new evidence):** a condition-based plan-health status in three tiers:

- **Red:** Strategy progress is currently blocked. That is a stall, an open Shortfall, or not Strategy-capable.
- **Yellow:** progress continues with recoverable drag. That is Capacity Deferral, overdue Demands, a recent Pricing-model Breach, or negative/absent trailing Net Earnings while trading.
- **Green:** none of the above, with fresh evidence.

Unknown is a separate state. Label it **"health against the Strategy"**, not "against forecast". Owner: a `MissionControl` read projection over `MarketDisposition`, `TradeProgress` and Generation credits. Cost: one projection function plus tests. No storage, no telemetry.

**For a forecast trend (the Operator's long-term direction):**

1. **Smallest owner-held addition:** retain the existing `planned_rate` and `planned_rate_evidence` (known or unknown, with model version) of each selected `market_trade` Commitment in the publishing Episode's `expectations`.
   - Owner: `FleetAllocation.MarketDomain.domain_decision` ([market_domain.ex:270-289][md-exp]).
   - Alternatively, store them on the Commitment, but that is a schema change and the Episode JSON map already exists.
   - This preserves "original expectations" per the Strategy Decision Episode definition and does no new estimation.
2. **The projection becomes:**
   - Expected Fleet rate = Σ known `planned_rate` over live trade Commitments, plus a count of unknown ones.
   - Realized rate = Net Earnings of trips with `sale_finished_at` in the same trailing window, per Ship-hour or per hour.
   - Coverage work contributes no credit rate by design and is labelled as scouting.
3. **Caveats to carry into the contract:**
   - `planned_rate` is deliberately conservative (worst observed cost and longest duration), so realized will usually exceed it. "Below plan" means below a floor, not below a midpoint.
   - It is unknown for every first trip on a new route, Good, quantity or Ship profile.
   - It is per selected trip, not a whole-Generation forecast.
   - A "by reset" projection additionally needs a fresh Generation Horizon, which is computed on demand only.

**Not required for either:** new tables, telemetry, a forecast model, or Operator-set targets. An Operator-set target, such as an attain "reach N credits by reset", would make "on plan" literal, but it is a Strategy-intent change and not a recovery deliverable.

## Limits and unknowns

- The deployed Revision 7 objective list was inferred from the rendered label, not read from the DB. Shortfall, Neutral Wait and Episode classification counts are DB-only and unverified.
- Thresholds are undecided: the trailing window length, the "below expectation" tolerance, and whether Shortfall is red or yellow. They belong to the recovery contract (#744) or the prototype.
- The capability/API-scope quarantine named in the Degraded Operation glossary entry has no implementation in `lib/` (grep `quarantin`: no matches). Today Degraded Operation means structural stall plus Pricing-model Breach.
- Historical objective validity applies a present-time 300 s age check to retired Generations ([mission_control.ex:1083-1095][mc-obs]), so old Generations read as unknown. This was already flagged in the prior note.

[md-exp]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/market_domain.ex#L270-L289
[fa-ev]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation.ex#L2126-L2136
[fa-insert]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation.ex#L1725-L1738
[fa-rate-doc]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation.ex#L100-L104
[fa-pub]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation.ex#L262-L268
[fa-rank]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation.ex#L2594-L2612
[fp-trade]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_planning.ex#L2746-L2797
[fp-intel]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_planning.ex#L2170-L2214
[mwr]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/market_work_rate.ex#L1-L134
[uw]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/unmet_work.ex#L30-L55
[sde]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/strategy_decision_episode.ex#L27-L69
[tp-doc]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/trade_progress.ex#L1-L35
[tp-build]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/trade_progress.ex#L60-L125
[tp-class]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/trade_progress.ex#L312-L325
[tp-trip]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/trade_progress.ex#L461-L499
[cc]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/credit_calibration.ex#L1-L15
[cc-breach]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/credit_calibration.ex#L408-L422
[oe]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_strategy/objective_evaluation.ex#L99-L141
[presets]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_strategy.ex#L37-L75
[mc-obs]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/mission_control.ex#L1052-L1122
[mcl-health]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders_web/live/mission_control_live.ex#L523-L574
[mcl-label]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders_web/live/mission_control_live.ex#L648-L684
[fg-rec]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_generation.ex#L726-L794
[fg-obs]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_generation.ex#L796-L849
[fg-int]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_generation.ex#L227-L252
[oc-obj]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/operator_conditions.ex#L72-L99
[gh]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/generation_horizon.ex#L1-L101
[sac]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/ship_acquisition_calibration.ex#L1-L20
[disp]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/mission_control/market_disposition.ex#L1-L294
[ss]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/lib/spacetraders/fleet_allocation/structural_stall.ex#L117-L131
[om]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/docs/agents/outcome-metrics.md
[obs]: https://github.com/bturney/spacetraders/blob/ca37d98de0670cfde5eab7e9d44231d0eee70135/docs/agents/observability.md#L76-L129
