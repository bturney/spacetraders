# Strategic observability and Operator experience — evidence/gap analysis

> **Status:** Non-normative design evidence for [#502](https://github.com/bturney/spacetraders/issues/502) C09/C10 and the accepted [#311](https://github.com/bturney/spacetraders/issues/311) information architecture. Companion to [strategic reasoning scenarios](strategic-reasoning-scenarios.md) (SR-01–SR-08). **Not** a PRD, new navigation model, new implementation roadmap, approved dashboard redesign, instrumentation mandate, or modification to Standing Authority.
>
> **Reviewed:** 2026-10-11. SpaceTraders source and existing documentation, plus dashboard JSON provisioned in the sibling `bturney/home-server-setup` repository. This is a **source-level inventory**, not a runtime screenshot review, Prometheus data audit, or proof that live dashboards are populated. Verify against current branches and deployed data at implementation time.

## The product question

The Fleet can issue an enormous number of successful API actions while making no useful progress. The Operator needs to distinguish a productive autonomous operation from busy-looking execution, investigate decisive choices, calibrate forecasts against *realized* evidence, and enjoy watching meaningful Fleet events unfold.

The accepted product division in #311 remains:

1. **Mission Control / Operations / World / Activity / Generations** answer, in normal Operator language, what the Fleet is achieving, why it chose its current approach, what happens next, and whether external authority is needed. Preserve Mission Control's 30–60 second outcome-first check; do not turn it into an engineering console.
2. **Grafana** provides diagnostic trends, quantitative comparisons, calibration investigations, and scoped system behavior. Use the agreed five dashboard families rather than another global dashboard architecture.
3. **Durable records + structured logs** provide the causal chain behind those summaries. Application PostgreSQL and authoritative game evidence are truth; Prometheus/Loki/Grafana are disposable projections, not alternate gameplay decision authorities.

The target is **understandability attached to every qualified capability**, not full visual polish at every implementation step. The exact deployment order remains governed by #502's bounded gate frontier. The active Gate 2B scope in [#684](https://github.com/bturney/spacetraders/issues/684) / [#691](https://github.com/bturney/spacetraders/issues/691) is unchanged.

## Evidence vocabulary and gap classes

Use project terms in [glossary map](../../GLOSSARY-MAP.md): Strategic Objective, Candidate Contribution, Fleet Commitment, Strategy Decision Episode, Net Earnings, Episode Cash Flow, Observation Demand, Binding, Attention, Intervention, Neutral Wait, and Shared World State.

Each suggested feature should classify its need:

- **PRESENT:** adequate evidence and at least a minimal surface exist; a better visualization is optional.
- **PRESENTATION:** evidence exists but needs explanation, composition, navigation, or visual treatment.
- **PROJECTION:** durable evidence exists, but a read-only, authenticated, bounded aggregation or causal join needs to be defined or checked.
- **INSTRUMENTATION:** the necessary observation, outcome association, duration, or bounded aggregate is not currently established; do not draw a chart implying it is known.
- **MODEL/QUALIFICATION:** the desired planner/executor behavior or its proof is not yet established. A dashboard cannot manufacture the absent semantic outcome.
- **VERIFY:** source availability, deployed series, completeness, or validity must be checked before assigning a definitive class.

A desired chart often has *two* statuses: the underlying **game outcome** may be modeled and durable, while its **time-series projection** is still missing.

## What already exists

### App views and causal data

- [`MissionControlLive`](../../lib/spacetraders_web/live/mission_control_live.ex) shows Strategy/Generation context, objective evaluations, Attention, market expected change versus receipt-backed Trade Margin / Net Earnings, observation-only spending, allocation dispositions (including stall, Shortfall, Capacity Deferral, Neutral Wait, Unallocated), and noteworthy Activity.
- [`OperationsLive`](../../lib/spacetraders_web/live/operations_live.ex) exposes Objective-grouped Endeavors and linked released-work evidence; [`ActivityLive`](../../lib/spacetraders_web/live/activity_live.ex) separates consequential events from raw API traffic; [`GenerationsLive`](../../lib/spacetraders_web/live/generations_live.ex) includes bounded historical comparisons.
- [`DecisionEpisodeLive`](../../lib/spacetraders_web/live/decision_episode_live.ex) already shows classification, calibration version, expected and actual outcome maps, retained evidence references, and contextual Grafana links.
- [`MissionControl.decision_episode_projection`](../../lib/spacetraders/mission_control.ex) exposes **alternatives and binding constraints** as well. Their omission from the concise Decision Episode view is a **presentation opportunity**, not by itself a reason to add new permanent tables.
- [`GrafanaLink`](../../lib/spacetraders_web/grafana_link.ex) scopes links with Generation, Revision, Decision Episode, Commitment, Intent, and MutationAttempt identities and time windows. Retain this traceability.
- [`TradeProgress`](../../lib/spacetraders/fleet_allocation/trade_progress.ex) attributes qualifying Market trades and supporting refuel/jump charges to their recorded root outcomes. Unknown monetary gaps remain unknown. This currently does **not** prove the full producer–hauler economics in SR-07.

### Prometheus / logs

- The [outcome metric contract](outcome-metrics.md) covers authoritative observed credits, observed-interval credits/hour, gross receipts/charges by bounded Intent/operation labels, Ship claim/Intent/nav counts, scan/chart/Contract state, and observation freshness. It explicitly distinguishes credit-balance change from per-contribution Net Earnings.
- The [observability guide](observability.md) records Fleet Allocation decisions, bounded reason codes, Revision reconciliation, classified structural stalls, attributable Market fuel, and high-cardinality IDs as **JSON log metadata**, not Prometheus/Loki stream labels.
- Contextual application pages already link to the correct Grafana family. Preserve the identity/time correlation; avoid making the Operator manually retype event IDs.

### Current Grafana layout (provisioned source inventory)

Dashboard source: [`bturney/home-server-setup/config/observability/grafana/provisioning/dashboards/`](https://github.com/bturney/home-server-setup/tree/main/config/observability/grafana/provisioning/dashboards).

| Existing dashboard | Metric visualizations (excluding text/log panels) | Current questions covered / limitations |
| --- | ---: | --- |
| [Strategy Outcomes](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/strategy-outcomes.json) | 2 | Fleet activity by kind, Intent transitions; not actual Strategic Objective trends or an expected-versus-realized series |
| [Economics and Capital](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/economics-capital.json) | 2 | Economic API rates and general Fleet activity; no durable Reservation/headroom or contribution Net Earnings series on this dashboard |
| [Fleet and Logistics](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/fleet-logistics.json) | 2 | Intent transitions and Fleet activity; not Ship-time utilization by economic purpose or multi-Ship dependency outcomes |
| [Intelligence and API Capacity](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/intelligence-api-capacity.json) | 6 | Governor/admission/rejection/queue-time trends; does not establish strategic usefulness of acquired information |
| [Reliability and Recovery](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/reliability-recovery.json) | 3 | Scrape availability, API error ratio, failed Intent transitions; lacks an outcome-based recovery duration/completion view |
| [Outcomes](https://github.com/bturney/home-server-setup/blob/main/config/observability/grafana/provisioning/dashboards/outcomes.json) | 16 | Richer credits, gross money flow, Fleet axes, freshness, charting, Contract counts; not a normalized profitability or causal contribution dashboard |

The current dashboard files are not empty; some underlying signals are useful. The specific gap is that **the five named diagnostic families mostly explain activity and software flow, while durable outcome evidence is elsewhere**. Avoid adding duplicate metrics when promoting or linking existing panels would answer the question.

## Operator question → evidence → surface gap matrix

| Operator question | Existing durable/evaluable evidence | Gap class and desired surface | Contracts / examples |
| --- | --- | --- | --- |
| **Are the Strategic Objectives improving?** | Mission Control objective evaluations; Generation/Revision context; observed credits and gaps | **PRESENTATION/PROJECTION:** compact objective-specific trends, comparable windows and known/unknown rate semantics. Avoid a universal KPI where attain/maintain/continuous differ. | #311; C09/C10 |
| **Is the Fleet profitable, after supporting costs?** | Market completed-trip Trade Margin, attributable supporting charges, observed credits, Episode Cash Flow and unknown-gap semantics | **PRESENTATION/PROJECTION:** earnings bridge and bounded economic trend where sufficient receipts exist; never equate balance delta, gross flow, margin, Net Earnings or counterfactual return. | C05/C10; SR-07 |
| **Why this choice instead of the runner-up?** | Strategy Decision Episode alternatives, expectations, binding constraints, evidence refs | **PRESENTATION:** a concise two-level “Why?” explanation with the decisive comparison and validity. If alternate economics were not recorded, say so. | #311; C02/C10; SR-02/07 |
| **What made the Fleet change its mind?** | selected/retained/superseded episodes, original evidence, Revision, Market Binding; Activity | **PRESENTATION/PROJECTION:** meaningful decision timeline and original-versus-new evidence comparison, with source/observation times. Do not manufacture a lifecycle for an unmodeled hypothesis. | C03/C05/C10; SR-04/05/08 |
| **What are Ships achieving together?** | Fleet Commitments, Claims, Reservations, Pledges, root Intents and outcomes for currently modeled work | **MODEL/QUALIFICATION then PRESENTATION:** once producer–hauler composition works, show dependent steps, quantities, exceptions, and combined result within Endeavor/Ship detail. | C02/C08/C09; SR-07 |
| **Why is a Ship Unallocated or apparently stationary?** | Mission Control Market dispositions, linked Neutral Wait and structural-stall episodes, Ship states | **PRESENTATION:** a quiet explicit reason and next re-evaluation time, with Attention only when the accepted state contract requires it. Do not call all stationary Ships stalled. | C06/C09; SR-05 |
| **Is capital actually free for the next buy?** | authoritative credits, protected floor, Reservations/exposure authorities, Shortfall and calibration | **PROJECTION:** truthful balance/floor/reserved/admitted/in-flight/unknown exposure at one time context; don't infer these from gross Prometheus trade counters. | C01/C02/C05/C10; ADR 0013; SR-03 |
| **Is the probe producing useful information or burning fuel?** | Observation Demands, fresh/stale Listings, Market-domain decisions, observation-only charge attribution | **PROJECTION/INSTRUMENTATION:** explain which decisions an observation supported and the cost of acquiring it; avoided-loss/ROI estimates must remain labeled as hypothetical, not realized income. | C03/C05/C06/C10; SR-04/05 |
| **Was a market quote deep/fresh enough to execute?** | Market Listing Binding with provenance, purchase/sale transactions, tradeVolume and freshness validity | **PRESENTATION:** quote/age/source/depth at selection and refresh, sales in bounded lots, and observed price drift. Never claim liquidity beyond one authorized transaction. | C03/C05; SR-04/07 |
| **How accurate are our forecasts?** | Episode expectations and attributable actual outcomes, calibration version | **PROJECTION** for like-for-like cohorts; **INSTRUMENTATION/MODEL** for missing time, mining-yield, counterfactual and multi-stage costs. Always show sample size and unknowns. | C05/C10/C11; SR-07/08 |
| **What happened while I was away?** | Activity, Decision Episodes, completed outcome receipts, Generation transitions | **PRESENTATION:** consequential, readable chronology (decisions, milestone, reallocation, failures, recovery). No raw API-request firehose on Mission Control. | #311; C09/C10 |
| **Did a failure stop all Ships or only a dependency?** | MutationAttempts, Intent states, scoped Safety Fences, capacity and stall dispositions | **PROJECTION/PRESENTATION:** affected scope, recovery progress/time and independent Ship continuation, with jump to technical logs. | C04/C09/C10/C11 |

A missing value should show **“unknown / incomplete evidence”**, with the missing source or cause where known. Neither zero nor “healthy” is a safe substitute.

## Five Grafana families: question-first augmentation ideas

These are **candidate panels and proof questions**, not a requirement to implement all of them or a claim their data already exists.

### Strategy Outcomes

- Desired: objective-specific progress/rate by Generation/Revision; Decision Episode selected → partially realized → realized/reset-censored distribution where complete; achieved outcome per Strategy-capable hour.
- Reuse: current Fleet activity, Intent transitions, Episode and Generation read projections. Investigate a bounded historical projection where Prometheus lacks an honest Strategy outcome metric.
- Avoid: treating selection count or Intent throughput as “Strategy success.” A high activity rate with no earnings must be visibly possible.

### Economics and Capital

- Desired: observed balance/floor/headroom and exposure **at the same authoritative boundary**; actual contribution Net Earnings versus supporting spend; observation-only spend kept separate; forecast-error cohorts where attribution is complete.
- Reuse: Outcomes credit plots, gross transaction counters, Episode/TradeProgress receipts. Add only proven, bounded aggregates; do not make per-episode IDs Prometheus labels.
- Avoid: summing unrelated gross sales/refuels into “profit”; showing a guessed in-flight balance after missing authoritative reads. “Credits/hr” from consecutive observations is **not** a Ship's productive earnings rate.

### Fleet and Logistics

- Desired: by-purpose Ship-time breakdown and true Unallocated/Neutral Wait reasons; elapsed versus planned transit/cooldown/wait; support dependencies and partial fulfillment; blocked subgraphs versus independently progressing Ships.
- Reuse: Ship claim/Intent/nav axes, current Endeavors, root Intents and movement facts.
- Gap: high-confidence historical duration classification and producer–hauler outcome modeling may not be present. Avoid labelling all claimed Ships “productive.”

### Intelligence and API Capacity

- Desired: fulfilled/open/overdue/unavailable Observation Demands, evidence reuse and age, coverage progression, cost of observation, decisions made possible by new evidence; separate objective demand from discretionary exploration.
- Reuse: governor admissions, rejections and queue time, known Market demands and observation-only fuel attribution.
- Gap: an attribution rule for **decision usefulness** (e.g. fresh evidence admitted or ruled out an option) is not equivalent to monetary ROI. Do not invent “profit created by scouting.”

### Reliability and Recovery

- Desired: unresolved attempts and age, actual disposition/classification, recovery time, structural stall episode age, recovery after Strategy Revision and restart, scope of affected work, independent continuation.
- Reuse: MutationAttempts, durable structural-stall episodes, bounded transition/error/admission metrics and correlated JSON logs.
- Avoid: inferring recovery from lack of recent errors or classifying a deliberate Neutral Wait as a stall.

For each added panel, document **question → source of truth → PromQL or read projection → freshness/unknown behavior → proof using real recorded evidence**. Test deployed dashboard queries against genuine output. A JSON file that renders is not proof the numbers are meaningful.

## App UX: preserve #311's four destinations and layered inspection

**No new top-level “Analytics”, “Autonomy”, or “Planner” destination.** Extend the existing approved surfaces, gradually and when appropriate.

### Mission Control — a 30–60 second narrative briefing

Keep status, ordered objective progress, genuinely material LIMITING factors, Attention/Intervention, and a short notable Activity feed. Where justified, add a coherent “current approach” sentence and the *next expected event*, e.g. “One Ship scouting an unobserved Marketplace; one Ship executing a trade; review when destination quote is available.” This summary must derive from the current Fleet Commitments and future Observation Demands. Use restrained sparklines; don't duplicate Grafana.

### Operations / Work / Ships — watch joint work unfold

Endeavors should explain **outcome first, then contributing Ships, current stage, next dependency, and recent consequential evidence**. A direct one-Ship trade may need only a progress line. A future producer–hauler contribution may merit a small dependency/timeline view:

```text
Acquire 80 ore [actual 80] → Transfer to Hauler A [actual 80]
    → Arrive at Fabrication Yard → Sell in bounded batches [50 + 30]
Hauler B: independent home trade (unaffected)
```

This is an **illustrative display concept from SR-07**, not a claim that the current runtime models or executes that graph. Cargo quantity lineage should be authoritative, and a transfer should never appear as revenue.

An Unallocated Ship belongs in the same readable operating context: why it has no admissible Fleet Commitment, whether it is waiting deliberately, the next known evidence boundary, and which limits affected its alternatives. Do not show generic “idle/blocked” when the exact reason is known.

### Decision Episode — highest-leverage inspection improvement

The existing page renders expected and actual maps, classification, calibration version, and evidence references. The backing `MissionControl.decision_episode_projection` also retains alternatives and binding constraints. Consider a **two-level “Why?” view**:

1. **Default:** chosen contribution / retained portfolio; governing Strategic Objective; decisive reason; meaningful closest alternative; important constraint; expected outcome with units and time horizon; actual classification.
2. **Expand:** alternatives and rejection reasons, assumptions and uncertainty, Binding provenance and ages, original versus re-evaluation evidence, cost/return attribution and unknown gaps, related Endeavors/Ships/Markets, contextual Grafana and logs.

If the planner has **not** recorded a supported counterfactual, state “comparison unavailable” rather than reverse-engineering why an alternative lost.

**Illustrative SR-07 explanation (not live data):**

> “Mining and hauling earned 19,550 credits in the hypothetical pilot, but forecast independent work could earn about 19,000 over the same time. The estimated 550-credit incremental advantage is narrow. Subsequent Market depth fell. The Fleet declined to assume the route is repeatedly superior.”

This correctly separates simulated realized earnings from estimated alternative earnings, and a business from unsupported market-causality speculation.

### World / Intelligence — make market knowledge inspectable

Where current Bindings support it, show Listing observation age, tradeVolume, source, last observed price changes, active Observation Demands, and whether evidence is usable **for a particular decision**, not an unconditional “fresh market” badge. Optionally expose game-supplied supply-chain reference relationships as *relationships*, distinct from invented refinery recipes or empirical downstream price effects.

### Activity and Generations — narrate consequential change

Major allocation changes, actual profits/losses, new opportunities, objective milestones, safe unwinds, recoveries, and Server Reset transitions deserve readable chronology. Routine refreshes and successful low-level API calls do not. Historical comparisons need comparable windows, active Strategy Revision and Generation scope, calibration version, and unknown intervals.

The approved #311 visual character—restrained Ship movement on Atlas, meaningful events and graceful mobile behavior—is part of making autonomy legible, but no extra decorative product scope is authorized here.

## Structured logs and causal investigation

Retain the [observability guide](observability.md)'s existing chain:

`Fleet Generation → Fleet Strategy Revision → Strategy Decision Episode → Fleet Commitment → root Intent → MutationAttempt`.

Keep identifiers in bounded retained records and structured JSON log metadata, not high-cardinality metric labels. Favor material boundary logs with stable/finite reason-code vocabularies:

- A decision was selected, retained, superseded, or publication rejected, with decisive reason and original evidence link.
- A required Market or owned-entity observation changed admissibility (age/depth/price), with relevant old-versus-new **evidence references** rather than invented causal interpretation.
- A critical action was prepared/sent/confirmed/absent/bounded unknown, with the exact attempt identity and affected dependency scope.
- A named underlying constraint or dependency cleared, another Ship remained independently productive, or a structural stall was recorded/deduplicated/resolved.
- A bounded contribution finished and attributable Net Earnings / supporting-cost gaps were reconciled to authoritative transaction evidence.

This is a **readability and joinability guideline**, not a request to log every evaluation cycle. Suppress repetitive identical status noise; never drop a distinct material transition. Structured logs must not become a second state machine or substitute for original evidence retention.

## Calibration and comparison: four necessary boundaries

1. **Forecast versus result:** compare predictions and realized outcome only for the same quantity, denominator, time horizon, and support-cost definition. Report sample size, evidence completeness, calibration version and changed conditions. A price quote is not a realized transaction.
2. **Actual versus hypothetical:** proposed alternative earnings, avoided losses, value of information and market-causality hypotheses are **counterfactual estimates**, not Fleet receipts. Keep them visually and semantically separate.
3. **Outcome versus activity:** claimed Ship fraction, requests per second, observation count or Intent transitions are not automatically economic output. A stationary Ship can be in a deliberate Neutral Wait; a busy Fleet can lose credits.
4. **Calibration versus Operator intent:** any future bounded, versioned, reversible model adjustment may alter model estimates at authorized reconciliation boundaries, **never** Strategic Objectives, priority, Hard Constraints, Preferences or active Revision.

Suggested investigations, *if their source models later exist*: market quote forecast error and time-to-refresh, Net Earnings forecast error excluding unknown charges, producer yield/cooldown error, predicted versus actual Ship-stage duration, fraction of observations supporting actual candidate decisions, and rejected/replanned portfolio regret estimates clearly labelled **estimated**.

## Traceability and sequencing *without* a new roadmap

| Evidence/use-case | Related scenario | Governing contract | Work should be considered when… |
| --- | --- | --- | --- |
| Reasoned choice with alternatives | SR-02/04/07 | C02/C09/C10; #311 | The relevant planner already records meaningful alternatives |
| Depth/quote validity around travel | SR-04/07 | C03/C05/C10 | A Market decision boundary and authoritative receipts can be replayed |
| Protected credit headroom and charges | SR-03 | C01/C02/C05/C10; ADR 0013 | The output can be built without second-guessing spending authority |
| Scoped completion and surplus work | SR-01/02 | C02/C04/C08/C09 | Shared outcomes and Cargo dispositions are behaviorally qualified |
| Probe value and bounded observation | SR-04/05 | C03/C05/C06/C10 | Observation Demands and costs are provenance-backed |
| Direct business versus supply effect | SR-06 | C05/C08/C10 | Direct receipts and candidate hypotheses are separately modeled |
| Producer–hauler lifecycle & economics | SR-07/08 | C02/C08/C10/C11 | The composed contribution exists at the real runtime seam |
| Restart, safety and truthful Attention | All where applicable | C04/C09/C10/C11 | Actual recorded outcomes and recovery verdicts are inspectable |

**Operational sequencing distinction:**

- **With each qualifying engine slice:** enough truthful, durable, navigable explanation to establish what work was selected, what actually happened, and what remains unknown. An opaque success should not count as a complete behavioral qualification.
- **Separately, when approved:** redesign panels/screens and implement richer visualization. Reuse existing signals first, prove deployed queries and readable desktop/mobile interactions, and add missing telemetry only after a real decision question demonstrates the need.
- **Not now by implication:** no automatic ticket generation, new Strategy settings, live monitoring changes, extra production API calls, or Gate 2B acceptance-criteria expansion. #502 and #311 decide the destination; the bounded current frontier decides the timing.

## Review questions for a later bounded design session

- Which top three questions are still unanswered when the Operator checks Mission Control for 60 seconds?
- Which decision-evidence fields are present but hard to interpret, versus genuinely missing?
- Can existing outcomes/credit history be composed into useful Grafana panels **without making misleading cross-Generation sums**?
- What minimum sourced time/quantity/cost attribution allows a future producer–hauler graph to be understandable?
- What exactly distinguishes a decision-worthy Activity event from repetitive API traffic, without loss of important recovery evidence?
- Which proposed trends are honest under sparse scrapes, stale observations, counter resets, unknown costs, and short sample windows?
- What slice of the accepted #311 desktop/mobile experience improves comprehension without adding a new operator job?

## Source references

- Authoritative destination: [#502](https://github.com/bturney/spacetraders/issues/502), especially C02, C03, C05, C06, C08, C09, C10, C11.
- Accepted UX target: [#311](https://github.com/bturney/spacetraders/issues/311), especially Mission Control, Operations, World, Explainability, Activity, Generations and Grafana handoff.
- Strategic examples: [SR-01–SR-08](strategic-reasoning-scenarios.md).
- Existing guides: [Observability](observability.md), [Outcome metrics](outcome-metrics.md), [Testing](testing.md).
- App sources: [Mission Control](../../lib/spacetraders_web/live/mission_control_live.ex), [Decision Episode](../../lib/spacetraders_web/live/decision_episode_live.ex), [Operations](../../lib/spacetraders_web/live/operations_live.ex), [Grafana links](../../lib/spacetraders_web/grafana_link.ex), [Market economics](../../lib/spacetraders/fleet_allocation/trade_progress.ex).
- Dashboard source: [home-server-setup provisioned Grafana dashboards](https://github.com/bturney/home-server-setup/tree/main/config/observability/grafana/provisioning/dashboards).

**Review goal:** confirm every source/instrumentation claim, retain the #311/#502 authority boundary, and preserve questions and illustrative design evidence without creating another implementation backlog.
