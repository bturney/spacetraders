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
| What are the last observed credits, Contracts, Fleet state, and chart coverage? | [Outcomes dashboard](../../../home-server-setup/config/observability/grafana/provisioning/dashboards/outcomes.json) in the sibling repo |
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

The sibling `outcomes.json` defines **SpaceTraders · Outcomes** (UID
`spacetraders-outcomes`), a variable-free, glanceable dashboard. It supplements
the five contextual diagnostic families above. These unscoped projections do
not provide Fleet Generation-normalized performance or replace durable evidence.

Exporter definitions: `lib/spacetraders/prom_ex/outcome.ex` and
`lib/spacetraders/prom_ex/fleet_outcome.ex`. Publication and projection rules:
`lib/spacetraders/outcomes.ex` and `lib/spacetraders/outcomes/fleet.ex`.
Writer-side transaction notifications live in `lib/spacetraders/outcomes/post_commit.ex`.
Labels below are exporter labels; Prometheus adds scrape labels such as `job`
and `instance`. Epochs and amounts are values; Agent, Ship, System, Waypoint,
Fleet Generation, and durable record identities remain outside metric labels.

### Metric contract

| Exact metric name | Type and labels | Definition |
| --- | --- | --- |
| `spacetraders_outcome_agent_credits` | Gauge; none | Credits from the latest authoritative owned Agent read, not a sum across Agents. |
| `spacetraders_outcome_contracts` | Gauge; `status` | Disjoint current Contract counts from the latest authoritative owned Contracts read. |
| `spacetraders_outcome_credits_transactions_total` | Counter; `intent_type`, `operation` | Sum of gross confirmed existing Ship transaction `total_price` receipts. |
| `spacetraders_outcome_ships_total` | Gauge; `claim`, `intent_state`, `nav_status` | Registered Ships of non-stale Agents, counted independently on each axis. Despite `_total`, this is current state, not a counter. |
| `spacetraders_outcome_systems_charted` | Gauge; none | Distinct Systems with known, non-invalidated scanned-Waypoint identity facts for non-stale Agents. |
| `spacetraders_outcome_waypoints_scanned_total` | Counter; none | Committed per-Waypoint Intelligence observations with source `scan_waypoints` since instrumentation. |
| `spacetraders_outcome_observed_at_seconds` | Gauge; `family=credits\|contracts\|transactions\|fleet\|chart` | Unix epoch seconds of the family's latest genuine observation or successful DB recompute. |
| `spacetraders_outcome_agent_credits_previous` | Gauge; none | Previous genuine authoritative balance in the current valid observation pair. |
| `spacetraders_outcome_agent_credits_previous_observed_at_seconds` | Gauge; none | Previous balance's Unix epoch seconds; `0` means the interval is unknown. |

Contract `status` is `pending`, `active`, `near_delivery`, `completed`, or
`expired`: unaccepted actionable offer; accepted actionable with outstanding
requirements; accepted actionable with requirements satisfied but awaiting
fulfillment; fulfilled; or expired by the applicable acceptance/completion
deadline. `near_delivery` is readiness, not a percentage threshold. Missing or
malformed deadlines do not prove expiration. Each successful Contracts
publication writes all five counts, including zeros for absent states.

Transaction `intent_type` is the bounded root Intent type: `navigate`,
`acquire_intelligence`, `acquire_resources`, `buy`, `sell`, `deliver`,
`transfer`, `install_module`, or `remove_module`. `operation` is `buy`, `sell`,
`refuel`, `jump`, `install_module`, or `remove_module`. These are allowed axes,
not preseeded combinations. Supporting purchases/refuels/refits retain their
root Intent label. Purchase, refuel, jump, and module expenditure and sales
receipts are positive gross amounts, not Trade Margin or Net Earnings. Emit
only confirmed existing `transaction.total_price` evidence: unknown monetary
amounts stay absent, including recovery that proves quantity alone. Contract
rewards have no existing instrumented total site; no inferred acceptance or
fulfillment payouts or Contract-income decomposition.

Supporting purchase/refuel/jump/module totals come from the existing retained
Credit Calibration Realization, after its attribution checks against the prepared
spend. A decoded receipt for different goods, module, or units, or without the
required post-charge credits, is not a proven amount and produces no counter or
transaction epoch. Root buy/sell totals retain their Market transaction validation.
The Intent domain owns the closed type vocabulary used by the exporter.

Ship series populate exactly one of the three labels; the other two are `""`.
Sum one axis only (for example `claim!=""`), or each Ship is counted three times.

| Ship axis | Bounded values | Meaning |
| --- | --- | --- |
| `claim` | `claimed`, `free` | Current unfenced, unreleased Fleet Commitment authority, or otherwise. |
| `intent_state` | `active`, `waiting`, `awaiting_confirmation`, `blocked`, `completed`, `infeasible`, `stopped`, `superseded`, `none`, `unknown` | Each Ship's latest root Intent lifecycle, including terminal states; `none` means no root Intent, `unknown` means unsupported state. |
| `nav_status` | `DOCKED`, `IN_ORBIT`, `IN_TRANSIT`, `unknown` | Newest retained whole-Ship/Fleet read or successful recorded mutation nav fact; missing/unsupported facts are `unknown`. |

Each dirty Ship axis rewrites its complete bounded vector, including zeros,
clearing previously nonzero counts after transitions or removal. A known empty
Fleet has zero Ships; utilization `claimed / (claimed + free)` is unknown when
the denominator is zero. A Claim establishes authority, not earnings.

Chart coverage requires a retained Waypoint `symbol` fact in state `known`,
without invalidation, whose Intelligence observation source is `scan_waypoints`.
Cached coordinates and public Waypoint listings/reads do not qualify. Multiple
scans in one System do not increase its distinct count; invalidation or Server
Reset can decrease it. Boot seeds the gauge from the current DB baseline.
The scan counter instead counts every committed per-Waypoint scan observation:
one response retaining N Waypoints adds N, and repeat Waypoints count again.
Bursts preserve their full event count even if chart projection fails. Boot
does not backfill scan events or manufacture a zero counter history. Metric
history begins at instrumentation and scraping, not at the underlying facts'
historical acquisition; counters can reset with the metrics process.

### Publication and failure isolation

One supervised `SpaceTraders.Outcomes` asynchronous worker owns all outcome
publications. `Outcomes.Fleet` is its DB projection helper. `Outcomes.PostCommit`
owns the SQL telemetry bridge and writer-side transaction buffers; neither helper
is a worker. Owned credits and Contracts observations queue inside their retention
transaction, publish only after the true outer commit, and are discarded on
rollback, including their epochs and previous-credit pairs.
Gameplay enqueues already-retained authoritative facts, confirmed transaction
deltas, or post-commit dirty notifications and continues without waiting for
metrics. Telemetry publication and aggregate SQL run out of band; outcome
metrics introduce no game API requests or periodic projection poller.

Fleet/chart changes share a default **2000 ms** coalescing window: dirty family
names combine, scan-event counts add, and each dirty family gets one aggregate
SQL query. Outer transaction rollback publishes no dirty change; commit sends
the notification. Boot schedules the initial full DB projections. Errors log
and drop the observation/projection rather than interrupt gameplay; the next
real change or boot can reconstruct DB gauges again. Successful/dropped DB
projections are counted by `spacetraders_outcome_fleet_recomputes_total` and
`spacetraders_outcome_fleet_projection_failures_total`, both with bounded
`family=claim|intent_state|nav_status|chart`.

Scrapes collect coherent metric bytes through the same worker mailbox; the
HTTP request process sends the response. A scrape neither queries game state
nor advances observation epochs.

### Sparse updates, periodic samples, and credits/hour

**Push-on-change** means publication follows real observations and durable
changes, including an equal-balance fresh read. Updates are sparse; Prometheus
still samples retained gauges periodically (the sibling scrape interval is
15 seconds). Idle therefore retains values, not an absence of scrape samples.
Each `observed_at_seconds` family advances only on its own observation or
successful recompute; `fleet` advances on a successful Ship-axis projection.

The dashboard's trends require a positive family epoch, age in **0–120
seconds**, and `up == 1`, matched `on(job,instance)`. After 120 seconds without
a family update, or on scrape failure, trends gap with null bridging disabled;
they never fill missing evidence with zero. Stats retain the last observed
balance, valid credits/hour interval, Ship count, and chart count while idle,
subject to initialized evidence and successful scrapes. The age table exposes
retained evidence age. Selected-range gross amounts use counter `increase`;
gross-flow trends use `rate` with the transactions freshness mask. These handle
counter resets but cannot recover amounts before the first scrape and are not
an exact ledger.

Last-interval credits/hour is `3600 * (current - previous) / (current_at -
previous_at)`, with `current_at` from `observed_at_seconds{family="credits"}`.
Require `previous_at > 0` and `current_at > previous_at`; match arithmetic
`on(job,instance)` because only the current epoch has a `family` label. It is
net balance change over elapsed observation time, including idle time, not a
counter rate or working-hour productivity. Equal balances yield zero, losses
remain negative, and the last valid interval stays stable during idle.

The pair uses distinct genuine observations of the same Agent/Fleet Generation
identity. Retained fact reuse, duplicate replay, and older observations do not
create a new interval; same-time reads cannot create a zero-duration pair.
An identity change invalidates the pair. Worker restart sets the previous epoch
to `0` and waits for two new post-start observations, ignoring pre-restart
replay; it does not restore a durable pair. A retained previous balance alone
is insufficient: the rate remains unknown until the time guards pass.

### Growing the family

Future outcome metrics follow `spacetraders_outcome_*`, bounded labels, the
same fail-soft worker and real-change taps, complete zeroed state vectors, and
family freshness metadata. Keep this contract and sibling `outcomes.json`
queries/descriptions in sync whenever names, labels, definitions, freshness,
or reset behavior change. Validate dashboard queries against scraped exporter
data; retain durable identities in evidence/logs rather than adding labels.
