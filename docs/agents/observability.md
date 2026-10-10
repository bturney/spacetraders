# Observability

Use this guide to move from Operator-visible durable evidence to correlated
telemetry. Mission Control and PostgreSQL remain authoritative; Grafana is a
disposable diagnostic surface.

## Source map

| Question | Current source |
| --- | --- |
| Is the Fleet Strategy succeeding? | Mission Control objective evaluations and `SpaceTraders.MissionControl.overview/1` |
| What decision was made, and how did it turn out? | `/decision-episodes/:id` and `strategy_decision_episodes` |
| How do Fleet Generations compare? | `/generations`, including the cross-Generation Decision Episode table |
| What is the Fleet doing now? | `/operations`, Fleet Commitments, Claims, Reservations, Pledges, and root Intents |
| What are the last observed credits, Contracts, Fleet state, and chart coverage? | SpaceTraders · Outcomes (`spacetraders-outcomes`); [outcome guide](outcome-metrics.md) |
| What software or API behavior explains a durable record? | The contextual Grafana family linked from that record |
| Where are dashboard definitions deployed from? | `../home-server-setup/config/observability/grafana/provisioning/dashboards/` |

The five Grafana families are **Strategy Outcomes**, **Economics and
Capital**, **Fleet and Logistics**, **Intelligence and API Capacity**, and
**Reliability and Recovery**. The generic **SpaceTraders** dashboard remains
the application-health entry point.

## Durable evidence

| Evidence | Durable identity and retention | Grafana role |
| --- | --- | --- |
| Fleet Strategy Revision | Immutable revision ID; retained with the Strategy | Filter supporting telemetry; never redefine Strategy |
| Fleet Generation | Generation ID; retained across Server Resets | Bound the reset chapter and relevant time range |
| Strategy Decision Episode | Episode ID, expected and actual outcomes, classification, evidence references, calibration version | Explain supporting system behavior around one durable decision |
| Fleet Commitment | Commitment ID and Decision Episode relationship | Explain current or released outcome work |
| Root Intent | Intent ID and durable progress | Explain Ship execution and waits |
| Mutation attempt | Attempt ID, consequence bounds, and outcome | Explain ambiguity and recovery without authorizing replay |

Losing Prometheus, Loki, or Grafana loses none of these records and changes no
gameplay authority.

## Contextual links

`SpaceTradersWeb.GrafanaLink` builds links from the configured
`GRAFANA_BASE_URL`. The production default is the tailnet-only URL documented
in `../home-server-setup`; the environment variable is an optional deployment
override.

Links contain no Grafana credentials. They carry only:

- `var-fleet_generation`
- `var-strategy_revision`
- `var-decision_episode`
- `var-commitment`
- `var-intent`
- `var-attempt`
- Grafana `from`, `to`, and `timezone` parameters

Episode links cover five minutes before selection through five minutes after
the last recorded outcome; an evaluating episode ends at `now`. Objective
links cover the current Fleet Generation. Attention links begin five minutes
before the condition was recorded and end at `now` while unresolved.

Durable IDs are high-cardinality values. They are retained as structured JSON
logger metadata and parsed by Loki at query time. They are not Prometheus
labels or Loki stream labels. Prometheus metrics keep bounded dimensions such
as endpoint, outcome, lane, owner, activity kind, Intent type, and Intent
state.

## Fleet Allocation pilot metrics

Market trade vs coverage pilot (#671); bounded labels only, IDs in logs:

- G1 `spacetraders_fleet_allocation_publication_total{operation,result,reason}`:
  every publish/replan/unwind outcome; log `Fleet Allocation publication`.
- G2 `spacetraders_fleet_allocation_market_domain_decisions_total{result,decisive_reason}`
  plus `..._trade_candidates_total`, `..._coverage_candidates_total`,
  `..._claimable_ships_total`, `..._selected_total` sums; log
  `Fleet Allocation Market domain decision` (warning when rejected/error).
- Rejected publication: durable episode `selection_kind = publication_rejected`,
  `rejection_reason` set, would-be Commitments in `alternatives`.
- G3 rejected Ship-role alternatives: episode `alternatives` entries with
  `kind = ship_role_alternative`.

## Family routing

| Originating question | Dashboard family |
| --- | --- |
| Objective status or expected-versus-actual episode outcome | Strategy Outcomes |
| Credit floor, market economics, Ship acquisition, or Ship refit exposure | Economics and Capital |
| Resource, Construction, Contract, transfer, or Fleet movement work | Fleet and Logistics |
| Operational Intelligence or API Capacity pressure | Intelligence and API Capacity |
| Failure, external authority, ambiguous mutation, fencing, or recovery | Reliability and Recovery |

Every episode first links to Strategy Outcomes. When its calibration version
identifies a narrower question, the episode also links to that family.

## Diagnostic sequence

1. Start from Mission Control, Generations, Operations, Activity, or the
   Decision Episode page. Record the durable identity and what is known versus
   unknown.
2. Open the supplied Grafana link rather than recreating filters manually.
   Confirm the family, identity variables, and time range before interpreting
   panels.
3. Compare bounded Prometheus trends with the correlated structured logs. A
   missing series or empty log result is unknown, not a measured zero.
4. Return to the Decision Episode for expectations, actual outcomes,
   classification, and every retained evidence reference. Grafana does
   not replace that evidence.
5. Diagnose from authoritative game evidence before proposing runtime changes.
   Telemetry can explain behavior but cannot establish game truth.

## Calibration boundaries

The current runtime records a calibration version with every Decision Episode
and compares that version beside expected and actual outcomes across Fleet
Generations. There is no autonomous path that edits an active Fleet Strategy
Revision.

Calibration is limited to versioned derived planning behavior at reconciliation
boundaries. It cannot change Operator-owned Strategic Objectives, Strategic
Priority, Hard Constraints, Preferences, or the active revision. A changed
model uses a new version, and retained episodes preserve the earlier version
and observations, making comparison and reversal possible without rewriting
history.

## Outcome metric family

**Outcome metrics:** read [the outcome guide](outcome-metrics.md) before changing
taps, labels, or dashboard queries; interpreting idle gaps or credits/hour;
or validating the native exporter. It holds the metric contract, publication
boundary, freshness/reset rules, sibling dashboard path, and verification steps.
