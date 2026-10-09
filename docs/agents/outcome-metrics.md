# Outcome metrics

Use for outcome instrumentation, query changes, idle gaps, or credits/hour.
Mission Control and PostgreSQL remain authoritative; metrics are projections.

## Sources

Paths relative to this repository root:

| Concern | Source |
| --- | --- |
| Metric names, types, labels | `lib/spacetraders/prom_ex/{outcome,fleet_outcome}.ex` |
| Publication, credit pairs, transaction allowlist | `lib/spacetraders/outcomes.ex` |
| DB projections and closed Ship-axis values | `lib/spacetraders/outcomes/fleet.ex` |
| Outer-commit buffering and SQL telemetry | `lib/spacetraders/outcomes/post_commit.ex` |
| Dashboard | `../home-server-setup/config/observability/grafana/provisioning/dashboards/outcomes.json` |

Dashboard: **SpaceTraders · Outcomes**, UID `spacetraders-outcomes`, variable-free.
Compare time windows; these unscoped projections provide no Generation-normalized
performance. Exporter labels are bounded; IDs stay in durable evidence/logs.
Prometheus supplies `job` and `instance`. Amounts and epochs are metric values.

## Metric contract

Every name below has prefix `spacetraders_outcome_`. Closed vocabularies live
in the sources above; transaction Intent types come from `Fleet.Intent.types/0`.

| Name suffix | Type; labels | Meaning |
| --- | --- | --- |
| `agent_credits` | Gauge; none | Latest authoritative owned Agent balance, not an Agent sum. |
| `contracts` | Gauge; `status` | Latest authoritative owned Contracts read; disjoint status counts. |
| `credits_transactions_total` | Counter; `intent_type`, `operation` | Gross confirmed existing Ship receipt amounts. |
| `ships_total` | **Gauge**; `claim`, `intent_state`, `nav_status` | Registered Ships of non-stale Agents; three independent axes. |
| `systems_charted` | Gauge; none | Distinct Systems with qualifying scanned-Waypoint facts for non-stale Agents. |
| `waypoints_scanned_total` | Counter; none | Committed per-Waypoint `scan_waypoints` observations. |
| `observed_at_seconds` | Gauge; `family` | Latest family observation/recompute epoch; `credits`, `contracts`, `transactions`, `fleet`, `chart`. |
| `agent_credits_previous` | Gauge; none | Previous genuine balance in the current credit pair. |
| `agent_credits_previous_observed_at_seconds` | Gauge; none | Previous epoch; `0` means unknown interval. |
| `fleet_recomputes_total`, `fleet_projection_failures_total` | Counters; `family` | Successful/failed projections; `claim`, `intent_state`, `nav_status`, `chart`. |

### Contracts and receipts

Contract statuses: `pending` = unaccepted actionable offer; `active` = accepted
with outstanding requirements; `near_delivery` = accepted requirements satisfied,
awaiting fulfillment; `completed` = fulfilled; `expired` = applicable deadline
passed. Missing/malformed deadlines prove nothing. Publish all five counts,
including zeros; near-delivery measures readiness, not percentage progress.

Receipts retain the **root Intent** label, including supporting spend. Purchase,
refuel, jump, and module charges and sales receipts are positive gross amounts,
distinct from Trade Margin or Net Earnings. Root buy/sell uses Market transaction
validation; supporting spend uses retained, attributable Credit Calibration
Realization charges. Mismatched goods/modules/units or missing post-charge credits
produce neither amount nor transaction epoch. Recovery proving quantity alone and
Contract reward stages have no instrumented amount. Series start at the first
confirmed transaction; allowed label combinations are not preseeded.

### Fleet and charting

Each Ship series populates **one axis**; the other labels are `""`. Sum one axis
only. Claim `claimed` means unfenced, unreleased Fleet Commitment authority;
`free` means otherwise. Intent state is the latest root lifecycle, including
terminal states; `none` means no root and `unknown` unsupported state. Navigation
uses the newest retained whole-Ship/Fleet read or successful mutation nav fact;
missing/unsupported facts are unknown. Rewrite each dirty axis's complete bounded
vector, including zeros. Empty Fleet = zero Ships; claimed/(claimed+free) with
zero denominator = unknown utilization. Claims establish authority, not earnings.

Chart coverage requires a known, non-invalidated Waypoint `symbol` fact from
`scan_waypoints`; public listings/reads and cached coordinates do not qualify.
Repeated scans within a System keep one distinct System; invalidation/Server Reset
can lower coverage. Boot restores the **current DB gauge baseline**. Scan events
instead count each committed Waypoint observation: N retained Waypoints add N;
repeats count again. Preserve burst event counts even if chart projection fails.
History starts at instrumentation/scraping; boot backfills neither events nor a
synthetic zero baseline. Counters can reset with the metrics process.

## Publication boundary

One asynchronous `SpaceTraders.Outcomes` worker owns publication. `Outcomes.Fleet`
projects DB state; `Outcomes.PostCommit` buffers writer notifications. Gameplay
enqueues and continues. Owned observations and dirty notifications publish after
the **true outer commit**; rollback discards observations, epochs, and credit pairs.
Metrics cause no game API calls or periodic projection polling.

Fleet/chart dirty names coalesce for **2000 ms**; scan counts add; each dirty
family gets one aggregate query. Boot schedules full DB projections. Errors log
and drop; a later real change or boot reconstructs DB gauges. Scrapes collect
coherent bytes through the same worker; the HTTP request process sends them.
Scraping advances no epoch and reads no game state.

## Idle gaps and credits/hour

**Sparse updates, periodic samples:** even equal-balance fresh reads update their
family epoch; Prometheus periodically samples retained values. Each epoch advances
only for its own observation/successful recompute; `fleet` advances on a successful
Ship-axis projection. Trends require positive epoch, age **0–120 seconds**, and
`up == 1`, matched `on(job,instance)`; otherwise show gaps with null bridging off.
Initialized stats retain last values while idle, subject to successful scrapes;
the age table exposes freshness. Missing evidence is unknown, not zero.

Credits/hour = `3600 * (current - previous) / (current_at - previous_at)`.
`current_at` is `observed_at_seconds{family="credits"}`. Require `previous_at > 0`
and `current_at > previous_at`; arithmetic matches `on(job,instance)` because only
the current epoch has `family`. This is net change over elapsed observation time,
including idle time. Equal balances yield zero; losses stay negative; the last
valid interval stays stable while idle. It is not working-hour productivity.

Pairs require distinct genuine observations of one Agent/Fleet Generation.
Retained reuse and duplicate/older observations do not shift the pair. Same-time
updates keep the previous distinct epoch, preventing zero-duration intervals.
Identity change invalidates the pair. Worker restart sets previous epoch
to `0` and waits for two new post-start observations, ignoring pre-start replay.
A retained previous balance alone is insufficient.

Gross range totals use counter `increase`; gross-flow trends use `rate` with the
transactions freshness mask. Both handle resets; neither recovers pre-first-scrape
amounts or forms an exact ledger.

## Change and verify

1. Extend the existing fail-soft worker/taps with bounded labels, complete state
   vectors, and family freshness. Keep this contract and sibling dashboard
   queries/descriptions aligned for names, definitions, freshness, and resets.
2. Drive real domain flows; assert telemetry-to-exporter values at existing outcome
   test seams. Run `scripts/verify`. Done: exit 0.
3. For HTTP transport changes, run the [native diagnostic](testing.md#native-outcome-http-diagnostic).
   For query changes, validate/render the sibling dashboard against genuine app
   scrapes. Done: affected queries return expected values, idle/unknown cases
   remain truthful, and rendered panels match the provisioned file.
