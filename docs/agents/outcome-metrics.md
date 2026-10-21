# Outcome metrics

Use for metric instrumentation or player-dashboard query changes.
PostgreSQL (Earnings records) and Mission Control remain authoritative; metrics are projections.

## Sources

| Concern | Source |
| --- | --- |
| Earnings metrics, `agent_credits` | `lib/spacetraders/prom_ex/outcome.ex` |
| `fleet_ships` | `lib/spacetraders/prom_ex/fleet_outcome.ex` |
| Publication (one emit point per metric) | `lib/spacetraders/outcomes.ex` |
| Ship status projection | `lib/spacetraders/outcomes/fleet.ex` |
| Outer-commit buffering | `lib/spacetraders/outcomes/post_commit.ex` |
| Dashboards | `../home-server-setup/config/observability/grafana/provisioning/dashboards/{money,fleet,strategy-outcomes}.json` |

Exporter labels are bounded; Ship symbol and route go in the `Earnings record`
Loki line. Prometheus supplies `job` and `instance`. Domain area is the metric
prefix; there are no namespaces.

## Metric contract

| Name | Type; labels | Meaning |
| --- | --- | --- |
| `earnings_credits_total` | Counter; `flow` (revenue, goods, fuel, other, expected), `source`, `ship_type`, `good`, `price_age` | Credits of committed Earnings records. |
| `earnings_trips_total` | Counter; `result` (beat, missed), `source`, `ship_type`, `good`, `price_age` | Committed Earnings records. |
| `earnings_ship_seconds_total` | Counter; `source`, `ship_type`, `good`, `price_age` | Ship-seconds from taking the work until its last disposal. |
| `fleet_ships` | Gauge; `status`, `ship_type` | Current Ships by their one status (`trading`, `scouting`, `waiting`, `stuck`, `busy_not_earning`, `busy_skipping_buys`). |
| `agent_credits` | Gauge; none | Latest authoritative owned Agent balance. |

`price_age` buckets: fresh <10 min, 10-30, >30, n/a. Unread Outcome metrics
(Contracts, transactions, charting, freshness epochs, credit pairs, recompute
counters, `ships_total`) are deleted; add a metric only with a dashboard panel
that reads it.

Money dashboard "unexplained" = change in `agent_credits` minus Net Earnings of
Earnings records (revenue minus goods, fuel, other).

## Publication boundary

One asynchronous `SpaceTraders.Outcomes` worker owns publication. `Outcomes.Fleet`
projects Ship statuses from the DB; `Outcomes.PostCommit` buffers writer
notifications. Gameplay enqueues and continues. Owned observations, dirty
notifications and Earnings records publish after the **true outer commit**;
rollback discards them. Metrics cause no game API calls or periodic polling.

Status dirty names coalesce for **2000 ms**; one aggregate query per dirty family.
Errors log and drop; a later real change or boot reconstructs. Scrapes collect
coherent bytes through the same worker. Missing evidence is unknown, not zero.

## Change and verify

1. Extend the existing worker with bounded labels and complete state vectors.
   Keep this contract and the sibling dashboard queries aligned.
2. Drive real domain flows; assert telemetry-to-exporter values at existing outcome
   test seams. Run `scripts/verify`. Done: exit 0.
3. For query changes, run `scripts/check-dashboard.py` and
   `scripts/validate-observability.sh --remote` in `home-server-setup`.
