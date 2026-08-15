# Refueling-Stop Navigation Policy

Research for [#140](https://github.com/bturney/spacetraders/issues/140), 2026-08-15.

## Decision

Use a same-system, stateful sequence of individual `navigate` legs. A stop is
eligible only when it is a known `MARKETPLACE` and the app has previously
confirmed `FUEL` in that market's on-site `tradeGoods`; on arrival, dock,
re-read the market, refuel, and re-read the ship before choosing the next leg.
Treat each `navigate` response as authoritative for reachability. Do not claim
that a complete route is feasible from coordinates and fuel capacity alone:
the supplied contract exposes no fuel-cost estimator or route quote.

This is a conservative first policy, not a guarantee that a planned stop still
sells fuel when reached. It must block with an actionable reason rather than
dispatch a leg to an unconfirmed refueling candidate.

## Authoritative Data

| Need | Authoritative data and use |
| --- | --- |
| Current ship state | `GET /my/ships/{shipSymbol}` supplies nav status/system/waypoint, flight mode, current and capacity fuel, cooldown, engine, and cargo. Re-read it before every leg and after arrival/refuel. [Ship model](../../priv/spec/models/Ship.json#L4-L63); [nav](../../priv/spec/models/ShipNav.json#L4-L21); [fuel](../../priv/spec/models/ShipFuel.json#L4-L33) |
| Candidate waypoints | `GET /systems/{systemSymbol}/waypoints` is paginated and returns symbols, system, coordinates, traits, and construction state. Filter by `MARKETPLACE`; coordinates may rank candidates, but are not a fuel-reachability proof. [List endpoint](../../priv/spec/SpaceTraders.json#L435-L530); [waypoint](../../priv/spec/models/Waypoint.json#L4-L59); [`MARKETPLACE` trait](../../priv/spec/models/WaypointTraitSymbol.json#L4-L10) |
| Market fuel | A refuel stop must have `MARKETPLACE`; `POST .../refuel` additionally requires that its market sells fuel. `GET .../market` exposes `tradeGoods` only while a ship is present, so a remotely enumerated marketplace cannot be confirmed as fuel-capable from the contract. Confirm `tradeGoods` contains `FUEL` only after arrival and docking. [Market endpoint](../../priv/spec/SpaceTraders.json#L585-L635); [market model](../../priv/spec/models/Market.json#L30-L45); [refuel endpoint](../../priv/spec/SpaceTraders.json#L2824-L2882); [`FUEL` trade symbol](../../priv/spec/models/TradeSymbol.json#L49) |
| Navigation legality | `navigate` requires `IN_ORBIT`, targets only a waypoint in the ship's current system, consumes required fuel, and makes most actions unavailable until arrival. Its successful response returns updated fuel plus route/ETA. Flight mode affects fuel consumption, but the bundled contract supplies neither a leg-cost formula nor a quote endpoint. [Navigate endpoint](../../priv/spec/SpaceTraders.json#L2326-L2399); [flight-mode update](../../priv/spec/SpaceTraders.json#L2401-L2459); [flight-mode model](../../priv/spec/models/ShipNavFlightMode.json#L1-L6) |

Uncharted waypoints are discoverable, but their real traits are replaced with
`UNCHARTED`; they cannot be selected as known marketplace stops until charted
or otherwise confirmed. [Waypoint list behavior](../../priv/spec/SpaceTraders.json#L435-L438);
[`UNCHARTED` trait](../../priv/spec/models/WaypointTraitSymbol.json#L4-L7).

## Feasible First Policy

1. Read the target and ship. Reject this navigation mode if their system
   symbols differ; inter-system travel needs Warp or Jump, not refueling legs.
2. Enumerate all pages in the ship's current system. Keep only charted
   `MARKETPLACE` waypoints. Mark those with an earlier on-site `tradeGoods`
   observation containing `FUEL` as confirmed stops; all others remain
   unconfirmed.
3. If the requested destination is directly navigable, use it. Otherwise,
   choose only a confirmed stop that makes geometric progress toward the target
   and is not already visited. Coordinates are a ranking heuristic only.
4. Before a leg, wait for arrival/cooldown completion; orbit if docked. Submit
   one `navigate` request and persist its returned destination, fuel, and ETA.
   Do not issue another action until authoritative arrival revalidation.
5. At a stop, dock; re-read its market; require `FUEL` in `tradeGoods`; refuel;
   require the returned `fuel.current` to be the expected usable amount; then
   repeat. If any condition fails, block and retain the ship at its current
   waypoint.

The policy is deterministic after its candidate set and tie-breaker are fixed,
but cannot be a complete offline pathfinder. A route with no already-confirmed
fuel stops is "unknown/unplanned", not proven impossible; discovering one
would require reaching it without relying on it for refueling.

## Live Cruise Experiment

On 2026-08-15, a controlled experiment moved the empty, full-fuel
`ORBITALIST-5` light freighter through three same-system `CRUISE` legs, then
confirmed its return to the starting waypoint. Each observed consumption matches
the nearest integer of Euclidean coordinate distance:

| Leg | Coordinates | Euclidean distance | Observed fuel |
| --- | --- | ---: | ---: |
| `A2` to `E48` | `(-4, -22)` to `(-56, -1)` | 56.08 | 56 |
| `E48` to `C43` | `(-56, -1)` to `(44, 151)` | 181.95 | 182 |
| `C43` to `A2` | `(44, 151)` to `(-4, -22)` | 179.54 | 180 |

The round trip consumed 418 fuel, exactly the sum of the three observations.
A prior independent `CRUISE` leg also matched: `(44, -11)` to `(-4, -22)`

This supports the empirical estimator
`round(sqrt((target.x - origin.x)^2 + (target.y - origin.y)^2))` for `CRUISE`.
It is not part of the bundled API contract, and it has only been observed on
two Ship configurations. A route Policy may use it to rank or reject a planned
leg conservatively, but the `navigate` response remains the authoritative
reachability and fuel result. Other flight modes require separate measurement.

## Failure Cases And App Fit

| Failure | Required policy result | Current code evidence |
| --- | --- | --- |
| No token, pending local arrival, or pending cooldown | Do not dispatch; report the local readiness reason. | `Fleet.navigate_ship/3` returns `:agent_token_missing`, and asks `ShipServer.ensure_ready/1` before the API call. [Fleet](../../lib/spacetraders/fleet.ex#L994-L1025); [ShipServer](../../lib/spacetraders/fleet/ship_server.ex#L72-L83) |
| Docked, in transit, cooldown, wrong system, invalid waypoint, or insufficient fuel | Do not retry blind. Re-read live ship state; orbit only when docked; otherwise block the leg and surface the API error. The client preserves 4xx gameplay errors as values, but currently normalizes only a subset of codes, so the raw code/message/data must be retained for route diagnostics. [Navigation contract](../../priv/spec/SpaceTraders.json#L2326-L2379); [API error handling](../../lib/spacetraders/api.ex#L361-L384); [current mappings](../../lib/spacetraders/api/gameplay_error.ex#L30-L56) |
| Stop is not a market, market does not list `FUEL`, refuel fails, refuel returns short, or credits are insufficient | Block at the stop; do not navigate onward. A market's historical fuel observation is stale by design and must be revalidated on arrival. | Existing autopilot checks `MARKETPLACE`, then on-site `tradeGoods`, and blocks on missing/short/failed refuel. [Fleet](../../lib/spacetraders/fleet.ex#L707-L767) |
| Waypoint listing or market lookup fails | Do not use partial map data to assert a route. Return discovery failure and retain any successfully confirmed stop data only as stale cache. | Pagination returns the failure plus collected pages, while `Fleet.list_waypoints/1` deliberately drops the partial list. [Pagination](../../lib/spacetraders/api/pagination.ex#L6-L45); [Fleet](../../lib/spacetraders/fleet.ex#L930-L950) |
| Cycle/no progress/no confirmed next stop | Block with `no_confirmed_reachable_refuel_stop`; include visited stops and target. Never attempt an unconfirmed stop as a required refuel leg. | No current route state or graph exists. `navigate_ship/3` makes one raw-symbol API call only. [Fleet](../../lib/spacetraders/fleet.ex#L1011-L1020) |

Current application scope is insufficient for this policy without new work:
`Fleet.list_waypoints/1` lists only the Agent headquarters system, the dashboard
accepts any non-empty waypoint symbol, and market lookup is UI-selection driven.
The API client can enumerate an arbitrary supplied system and read a market, but
it has no route planner, no persistent fuel-stop observations, and no API method
to set flight mode or request a fuel estimate. [Fleet](../../lib/spacetraders/fleet.ex#L930-L958);
[dashboard input](../../lib/spacetraders_web/live/dashboard_live.ex#L160-L199);
[API waypoint/market methods](../../lib/spacetraders/api.ex#L296-L326).
