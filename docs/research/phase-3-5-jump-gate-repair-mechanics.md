# Jump-gate construction and repair mechanics

Research date: 2026-08-21. The bundled `priv/spec/SpaceTraders.json` and its referenced files under `priv/spec/models/` are treated as contract ground truth. Current behavior claims below use only first-party SpaceTraders documentation, release notes, and public API responses.

## Bottom line

Construction is a waypoint-level, globally shared material counter. Discover a candidate from `Waypoint.isUnderConstruction`, read its complete requirement ledger from `get-construction`, move a cargo-carrying Ship to that exact waypoint, and submit required cargo through `supply-construction`. The successful response returns both the updated `Construction` and the supplying Ship's updated `ShipCargo`. Completion is directly observable as `Construction.isComplete == true`, all material `fulfilled` counts reaching `required`, and the Waypoint's `isUnderConstruction` becoming false.

A `JumpGate` does **not** expose repair state, activation state, completion time, contributors, or a repair event. It exposes only `symbol` and `connections`; an unfinished gate can already expose its connections. Therefore gate connection visibility is not completion evidence. Completion must be observed through `Construction` and/or `Waypoint`.

## Discovery and requirements

1. `get-system-waypoints` (`GET /systems/{systemSymbol}/waypoints`) returns paginated `Waypoint` values and supports `type` and `traits` filters. `get-waypoint` returns one `Waypoint`. The required `Waypoint.isUnderConstruction` boolean is the contract-level discovery signal; `Waypoint.type == JUMP_GATE` identifies a gate. The list operation has no `isUnderConstruction` query filter, so filtering construction state is a client-side step after listing candidates, commonly after narrowing by `type=JUMP_GATE`. Contract references: operations `get-system-waypoints`, `get-waypoint`; schemas `Waypoint`, `WaypointType`.
2. Do not infer construction from the `UNDER_CONSTRUCTION` trait. Although bundled schema `WaypointTraitSymbol` includes that enum value, the current official response for unfinished gate `X1-FT96-I58` has `isUnderConstruction: true` but only the `MARKETPLACE` trait, and the official `traits=UNDER_CONSTRUCTION` query returns no waypoints in that same system: [unfinished Waypoint response](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints/X1-FT96-I58), [`UNDER_CONSTRUCTION` trait-filter response](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints?traits=UNDER_CONSTRUCTION).
3. `get-construction` (`GET /systems/{systemSymbol}/waypoints/{waypointSymbol}/construction`) returns `Construction { symbol, materials, isComplete }`. Each `ConstructionMaterial` gives `tradeSymbol`, `required`, and `fulfilled`; the outstanding quantity is therefore `required - fulfilled`. Contract references: operation `get-construction`; schemas `Construction`, `ConstructionMaterial`, `TradeSymbol`.
4. The operation description says `get-construction` requires `Waypoint.isUnderConstruction == true`, but the current server retains and serves a completed construction record after the Waypoint flag becomes false. For example, the official completed-gate responses show `isUnderConstruction: false` on the Waypoint while construction remains readable with `isComplete: true`: [completed Waypoint](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z), [completed Construction](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z/construction). Treat this persistence as observed behavior, not a guaranteed contract precondition.
5. Requirements are data, not constants. In the current reset, the sampled unfinished site reports `FAB_MATS` 1600 required/0 fulfilled, `ADVANCED_CIRCUITRY` 400/0, and `QUANTUM_STABILIZERS` 1/1: [current unfinished Construction response](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints/X1-FT96-I58/construction). These values may change across sites or resets; read them from `Construction.materials`.

## Supply preconditions and effects

`supply-construction` is `POST /systems/{systemSymbol}/waypoints/{waypointSymbol}/construction/supply`, authenticated with `AgentToken`, with required body fields `shipSymbol`, `tradeSymbol`, and `units`. The bundled contract does not declare a positive minimum for `units`; callers should not invent one as a bundled-contract fact. Contract reference: operation `supply-construction` and its inline request schema.

The explicit constraints are:

- The target Waypoint must be under construction. Contract reference: `supply-construction` description and `Waypoint.isUnderConstruction`.
- The named good must be required and not already fulfilled. The official error catalogue names `constructionMaterialNotRequired` (4800) and `constructionMaterialFulfilled` (4801): [official Construction Error Code section](https://spacetraders.io/api-guide/response-errors#construction-error-code).
- The Ship must be at the construction location. The official error catalogue names `shipConstructionInvalidLocationError` (4802): [official Construction Error Code section](https://spacetraders.io/api-guide/response-errors#construction-error-code).
- The Ship must carry the supplied good. The operation description states that the good must be in Ship cargo. Cargo amount and capacity are observable through `ShipCargo.units`, `ShipCargo.capacity`, and `ShipCargo.inventory`. Contract references: operation `supply-construction`; schemas `ShipCargo`, `ShipCargoItem`.
- The request is authenticated and names a Ship controlled through the caller's agent token. Contract reference: `supply-construction.security` and request `shipSymbol`.

On HTTP 201, supplied units are removed from the Ship cargo and added to the site's fulfilled materials. The response returns both updated values as `{ construction: Construction, cargo: ShipCargo }`; no `Agent`, credits transaction, `ShipNav`, or `Cooldown` is returned. Contract reference: operation `supply-construction` 201 response.

The contract does not define partial acceptance, clamping, or idempotency. In particular, it does not say that an over-supply is reduced to the remaining requirement, and a retry is not declared safe. The response's paired construction/cargo state is the authoritative result of a successful call.

## Ship capabilities, navigation state, and cooldown

- Construction supply requires cargo and exact location, but the operation declares no frame, role, module, mount, reactor, engine, crew, fuel, or jump-drive requirement. `Ship.cargo` is the only specialized Ship capability directly consumed by `supply-construction`; larger cargo capacity changes delivery batch size, not eligibility. Contract references: schemas `Ship`, `ShipCargo`; operation `supply-construction`.
- Reaching the gate uses ordinary in-system navigation. `navigate-ship` requires the Ship to be in orbit, stay within its current system, and have enough fuel; most Ship actions are unavailable while it is in transit. Its returned `ShipNav.route.arrival` and later `ShipNav.status` distinguish transit from arrival. Contract references: operation `navigate-ship`; schemas `ShipNav`, `ShipNavStatus`, `ShipNavRoute`.
- Buying construction goods is a separate state constraint: `purchase-cargo` requires the Ship to be docked at a Waypoint with the `MARKETPLACE` trait whose market sells the good, is limited by market `tradeVolume`, and adds goods to cargo. Contract reference: operation `purchase-cargo`.
- `orbit-ship` and `dock-ship` are idempotent state transitions. Orbit permits navigation but blocks local market/shipyard access; docking permits local market/shipyard access but blocks navigation. Contract references: operations `orbit-ship`, `dock-ship`; schema `ShipNavStatus` (`IN_TRANSIT`, `IN_ORBIT`, `DOCKED`).
- The generic cooldown contract says a Ship cannot perform additional actions until cooldown expiry, while action descriptions elsewhere qualify this as “certain actions.” `get-ship-cooldown` returns `Cooldown` or HTTP 204 when none exists. However, neither `supply-construction` nor the construction error catalogue states whether supply is cooldown-gated. Contract references: operation `get-ship-cooldown`; schema `Cooldown`; official general cooldown error `cooldownConflictError` (4000) in the [official error catalogue](https://spacetraders.io/api-guide/response-errors#general-error-codes).
- No source found states that construction supply requires `DOCKED` or `IN_ORBIT`; the only construction-specific navigation error published by SpaceTraders is invalid location 4802. The contract also does not state whether an in-transit Ship whose `waypointSymbol` still names an endpoint qualifies. Conservatively, “arrived at the exact waypoint” is established; dock/orbit eligibility is not.

## Progress and completion observation

There are three distinct API surfaces:

| Surface | Construction evidence | Contract meaning |
| --- | --- | --- |
| `Waypoint` | `isUnderConstruction` | Current construction flag |
| `Construction` | each `fulfilled / required`; `isComplete` | Requirement-level progress and direct completion flag |
| successful supply response | updated `construction` plus updated `cargo` | Immediate accepted result of this delivery |

The direct completion condition is `Construction.isComplete == true`; material counters explain why. A completed current response has every `fulfilled == required`: [official completed Construction response](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z/construction). Independently, the corresponding Waypoint reports `isUnderConstruction: false`: [official completed Waypoint response](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z).

The API is multiplayer and the counters are shared server state: SpaceTraders introduced construction as something “players can supply,” and described starting-system gates as needing completion before travel outside the system: [official v2.1 release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0). Consequently, progress can change between reads because another player supplies material. The bundled contract exposes no version, ETag, reservation, contributor, or per-agent contribution field.

No bundled operation exposes a construction progress event, completion event, subscription, timestamp, or webhook. Observation is through the response to one's own successful supply and subsequent reads of `get-construction`/`get-waypoint`.

## What a repaired jump gate exposes

`get-jump-gate` (`GET /systems/{systemSymbol}/waypoints/{waypointSymbol}/jump-gate`) requires a `JUMP_GATE` Waypoint and returns schema `JumpGate`. That schema has exactly two required fields: `symbol` and `connections`, where connections are other gate Waypoint symbols. It has no construction or operational-status field. Contract references: operation `get-jump-gate`; schema `JumpGate`.

Connection data is not proof of repair. The current unfinished `X1-FT96-I58` has `isUnderConstruction: true` and `Construction.isComplete: false`, yet its official jump-gate response already lists four connections: [unfinished Waypoint](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints/X1-FT96-I58), [unfinished Construction](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints/X1-FT96-I58/construction), [unfinished gate connections](https://api.spacetraders.io/v2/systems/X1-FT96/waypoints/X1-FT96-I58/jump-gate). A repaired gate exposes the same shape: [completed gate connections](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z/jump-gate).

The API enforces construction state when a jump is attempted: the official error list includes `shipJumpOriginUnderConstructionError` (4256) and `shipJumpDestinationUnderConstructionError` (4262): [official Ship Error Codes](https://spacetraders.io/api-guide/response-errors#ship-error-codes). But `JumpGate` itself does not say whether it is usable. For completion confirmation, use `Construction.isComplete` and/or `Waypoint.isUnderConstruction`, not a non-empty `connections` list and not an attempted jump.

The repaired-gate API does not expose who repaired it, how much any Agent supplied, when completion occurred, whether there was a separate activation step, gate health/condition, or a “repaired” label. The bundled surface supports only the construction ledger/flags plus the static-looking connection list.

## Material uncertainties and contract gaps

1. **Docked versus orbiting supply:** neither the bundled operation nor the official construction errors specifies a required nav state. Exact-location error 4802 is documented; a dock/orbit constraint is not.
2. **Cooldown interaction:** the generic cooldown rule exists, but no primary source found says whether `supply-construction` is one of the blocked actions.
3. **Excess and concurrent supply:** no primary source specifies over-supply behavior, partial acceptance, races between suppliers, or the exact failure returned when another player fulfills the remainder first.
4. **Post-completion construction reads:** the current API serves completed records even though the operation description says the Waypoint must be under construction. This is useful observed behavior but not guaranteed by the bundled contract.
5. **Material recipe stability:** the sampled current recipe is not a schema guarantee and can change with resets or balancing.
