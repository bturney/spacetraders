# Cross-System Mobility by Jump and Warp

Research for GitHub issue [#181](https://github.com/bturney/spacetraders/issues/181), under **Single-Ship expansion through cross-System mobility - Phase 3.5 map**.

Researched 2026-08-21. The bundled OpenAPI 3.0.1 document identifies itself as SpaceTraders API v2.3.0 and is treated here as contract ground truth (`priv/spec/SpaceTraders.json:1-26`). External sources are first-party SpaceTraders documentation, API responses, error catalogue, and release notes. “Contract” below means the bundled specification; “current observation” means reset-specific or documentation behavior that is not guaranteed by that contract.

## Answer

**Jump-gate repair is not always required.** A jump needs a complete origin gate and a complete connected destination gate. Repair/construction is required only where either required gate is under construction. A gate that is already complete can be used without supplying construction materials. A system with no usable gate can instead be entered by warp, provided the ship has a warp-drive module and enough ordinary ship fuel.

The shortest proof of cross-System arrival differs by mechanism:

- A successful `jump-ship` response is itself an instantaneous-arrival result: HTTP 200 “Jump successful” includes `data.nav`, whose `ShipNav.systemSymbol`, `waypointSymbol`, and `route.destination` identify the new location, plus the post-jump `Cooldown` and antimatter `MarketTransaction` (`priv/spec/SpaceTraders.json:2252-2324`; schemas [`ShipNav`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipNav.json), [`ShipNavRoute`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipNavRoute.json), and [`Cooldown`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/Cooldown.json)).
- A successful `warp-ship` response proves that transit started, not that arrival time has elapsed. It returns `data.nav` and `data.fuel`, and the route contains the expected arrival timestamp. Authoritative arrival is a later `get-ship-nav` result whose `ShipNav.status` is no longer `IN_TRANSIT` and whose `systemSymbol`/`waypointSymbol` and `route.destination` match the target (`priv/spec/SpaceTraders.json:2472-2581`; [`ShipNavStatus`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipNavStatus.json)).

## Contract Facts

### Discovering routes and targets

1. `get-systems` (`GET /systems`) lists systems; `get-system` gets one system; `get-system-waypoints` lists its waypoints (`priv/spec/SpaceTraders.json:328-464`). These are enough to discover cross-System warp targets and locate waypoints of type `JUMP_GATE`. Uncharted waypoint traits can be hidden behind `UNCHARTED`, but waypoint type and coordinates remain part of the waypoint record.
2. `get-jump-gate` (`GET /systems/{systemSymbol}/waypoints/{waypointSymbol}/jump-gate`) requires a waypoint of type `JUMP_GATE` and returns `JumpGate` (`priv/spec/SpaceTraders.json:690-741`). `JumpGate.symbol` is the gate and `JumpGate.connections` is the array of waypoint symbols having corresponding connected gates ([`JumpGate` schema](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/JumpGate.json)). Route discovery for jump is therefore a graph traversal over gate waypoint symbols, not arbitrary system coordinates.
3. `get-waypoint` exposes `Waypoint.isUnderConstruction`; `get-construction` exposes `Construction.isComplete` and material progress. The former is the precondition advertised by `get-construction`; the latter is the positive completion signal (`priv/spec/SpaceTraders.json:743-794`; [`Waypoint`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/Waypoint.json); [`Construction`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/Construction.json)).

### Jump constraints

`jump-ship` (`POST /my/ships/{shipSymbol}/jump`) has these normative constraints (`priv/spec/SpaceTraders.json:2252-2324`):

- The ship must be in orbit.
- The target request field is `waypointSymbol`, and it must be a connected waypoint.
- The operation jumps instantly.
- One unit of antimatter is purchased and consumed from the market when jumping; its market price can change.
- The response requires `nav`, `cooldown`, `transaction`, and `agent`.
- The operation does **not** state that a jump-drive module or mount is required.

The official error catalogue sharpens constraints omitted from the success schema. Relevant current names are `CooldownConflictError` (4000), `ShipInTransitError` (4214), `ShipNotInOrbitError` (4236), `ShipJumpInvalidOriginError` (4254), `ShipJumpInvalidWaypointError` (4255), `ShipJumpOriginUnderConstructionError` (4256), and `ShipJumpDestinationUnderConstructionError` (4262) ([live first-party error catalogue](https://api.spacetraders.io/v2/error-codes); [documented ship-error list](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes)). In particular, errors 4256 and 4262 establish that **both** endpoint gates must be complete; they do not establish that every gate begins incomplete.

The older documentation list still contains legacy names such as `ShipJumpMissingModuleError`, `ShipJumpMissingAntimatterError`, and `ShipJumpFromGateToGateError`, while the live v2.3.0 catalogue does not. Those legacy entries must not override the bundled v2.3.0 operation contract or current catalogue.

### Warp constraints

`warp-ship` (`POST /my/ships/{shipSymbol}/warp`) has these normative constraints (`priv/spec/SpaceTraders.json:2514-2581`):

- The ship must be in orbit.
- The destination request field is `waypointSymbol`, described as a target destination in another system.
- The ship must have a Warp Drive **module** installed.
- Warp consumes ordinary fuel from `ShipFuel`; the response returns updated `fuel` and `nav`.
- Transit takes time. The route carries expected arrival, and most actions are unavailable before arrival.

The current error catalogue confirms `WarpInsideSystemError` (4235), `ShipNotInOrbitError` (4236), `ShipMissingWarpDriveError` (4241), `ShipInTransitError` (4214), and the general `CooldownConflictError` (4000) ([live catalogue](https://api.spacetraders.io/v2/error-codes)). The contract does not publish a warp-distance formula, maximum range formula, or a separate warp cooldown in the operation response. The installed module’s `range` field may describe range, but no bundled operation text defines how it is enforced.

### Modules, mounts, fuel, and acquisition

- Cross-System capability is module-based only for warp. No mount is named by either mobility operation. `ShipMount` has no warp or jump symbols ([`ShipMount`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipMount.json)).
- `ShipModule` includes `MODULE_WARP_DRIVE_I`, `_II`, and `_III`, with generic `requirements` for reactor power, crew, and module slots and an optional `range` ([`ShipModule`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipModule.json); [`ShipRequirements`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipRequirements.json)). Although that current model file also still lists `MODULE_JUMP_DRIVE_*`, v2.1 release notes explicitly say jump-drive modules were removed, and the v2.3.0 `jump-ship` contract requires none ([v2.1 release](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)).
- `get-ship-modules` enumerates installed modules. `install-ship-module` requires the desired module in cargo and returns the resulting module list, cargo, agent, and transaction (`priv/spec/SpaceTraders.json:3566-3693`). The live errors add shipyard, credit, slot, power, and crew failure modes (`ShipModuleNoShipyardError`, `ShipModuleInsufficientCreditsError`, `ShipMissingSlotsError`, `ShipMissingPowerError`, `ShipMissingCrewError`), but the bundled install operation does not fully spell out those prerequisites.
- A complete ship with a warp drive may instead be acquired through `purchase-ship`. Contract prerequisites are an owned ship already at a waypoint with the `Shipyard` trait, a shipyard selling the requested `ShipType`, and sufficient credits; templates may include modules and mounts (`priv/spec/SpaceTraders.json:1461-1521`). `get-shipyard` only exposes currently available ship details when a ship is present (`priv/spec/SpaceTraders.json:637-688`), and `ShipyardShip.modules` reveals whether a template carries a warp drive ([`ShipyardShip`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipyardShip.json)).
- Warp fuel is the ship tank represented by `ShipFuel.current`, `capacity`, and optional `consumed` ([`ShipFuel`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipFuel.json)). `refuel-ship` normally requires docking at a `Marketplace` selling fuel; each market unit restores 100 tank units. It can also use `FUEL` cargo through `fromCargo` (`priv/spec/SpaceTraders.json:2824-2902`).
- Jump antimatter is not cargo under the contract’s stated flow: `jump-ship` automatically purchases and consumes one unit and returns a `MarketTransaction`. Consequently the direct prerequisites are a usable gate market and enough agent credits, not cargo space or a mount. `get-market` prices and recent transactions are visible only with a ship present at the market (`priv/spec/SpaceTraders.json:585-635`; [`Market`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/Market.json)). The contract does not define fallback behavior if the gate market cannot make the automatic purchase.

### Construction interaction

`supply-construction` (`POST /systems/{systemSymbol}/waypoints/{waypointSymbol}/construction/supply`) applies only where `isUnderConstruction` is true. The named `shipSymbol` supplies `tradeSymbol` and `units`; those goods must be in ship cargo and are removed into the site. A successful 201 returns updated `Construction` and `ShipCargo` (`priv/spec/SpaceTraders.json:796-852`). `ConstructionMaterial` exposes `required` and `fulfilled`, while `Construction.isComplete` is the definitive aggregate flag ([`ConstructionMaterial`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ConstructionMaterial.json)).

The construction error set adds `ConstructionMaterialNotRequired` (4800), `ConstructionMaterialFulfilled` (4801), and `ShipConstructionInvalidLocationError` (4802) ([live catalogue](https://api.spacetraders.io/v2/error-codes)). Therefore supplying a gate is cargo hauling to the construction waypoint, not a universal “repair action,” and it cannot be assumed necessary or valid after completion.

### Cooldown, transit, and arrival

- Jump is instantaneous but creates a distance-based cooldown. `Cooldown` exposes `totalSeconds`, `remainingSeconds`, and optional `expiration`; the v2.1 release notes explicitly retain distance-based cooldown after the gate rework ([v2.1 release](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)). `get-ship-cooldown` retrieves current cooldown (`priv/spec/SpaceTraders.json:1822-1865`). Cooldown limits subsequent cooldown-bearing actions; it is not transit time.
- Warp behaves like navigation: the initial success response places the ship on a timed route, with `ShipNav.status = IN_TRANSIT` until arrival. `ShipNav.route.origin`, `destination`, `departureTime`, and `arrival` distinguish the endpoints and expected completion ([official navigation guide](https://docs.spacetraders.io/game-concepts/ship-navigation#warping); [`ShipNavRoute`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipNavRoute.json)).
- Both actions require orbit at departure. `orbit-ship` exists to move the ship to `IN_ORBIT`; `ShipNavStatus` is exactly `IN_TRANSIT`, `IN_ORBIT`, or `DOCKED` (`priv/spec/SpaceTraders.json:1611-1658`; [`ShipNavStatus`](https://github.com/SpaceTradersAPI/api-docs/blob/main/models/ShipNavStatus.json)).

## Gate-State Alternatives

| Situation | Viable contract-backed path | What must be established |
|---|---|---|
| Origin and connected destination gates complete | Jump directly | Ship at origin gate and in orbit; destination appears in `JumpGate.connections`; no active blocking cooldown; enough credits for one automatically purchased antimatter unit. |
| Origin gate incomplete | Complete origin construction, then jump; or warp instead | `Waypoint.isUnderConstruction` / `Construction.isComplete`; outstanding `ConstructionMaterial`; a warp drive and fuel if bypassing construction. |
| Destination gate incomplete | Complete destination construction before jumping; or warp to a waypoint in that system | Error 4262 blocks the jump even if the origin is complete. Supplying the remote site itself may require an already mobile ship or collective completion by other agents. |
| Gate exists but has no connection to desired gate | Follow a multi-hop path through `connections`, waiting out each jump cooldown; or warp | Each graph edge and each endpoint gate’s completion state. |
| Destination system has no jump gate | Warp | The v2.1 gate rework explicitly says systems without gates cannot be jumped to and recommends warp ([release](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)). |
| No usable gate at origin | Warp | Warp does not state a gate-origin requirement; it requires orbit, installed warp-drive module, an other-system waypoint target, and fuel. |
| No warp drive and no usable complete gate path | Acquire/install a warp drive, acquire a warp-capable ship, or contribute to gate completion | There is no third cross-System movement operation in the bundled contract; ordinary `navigate-ship` is same-system only (`priv/spec/SpaceTraders.json:2326-2400`). |

## Current First-Party Observations

These observations demonstrate possibility and current universe state; they are not durable contract promises because resets regenerate universe state.

- The live API reported v2.3.0, reset date 2026-08-16, and weekly resets when sampled ([status response](https://api.spacetraders.io/v2)).
- In that reset, waypoint [`X1-RK60-AE9Z`](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z) is a `JUMP_GATE` with `isUnderConstruction: false` and a `MARKETPLACE`. Its [`Construction` response](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z/construction) is already `isComplete: true` with all materials fulfilled. Its [`JumpGate` response](https://api.spacetraders.io/v2/systems/X1-RK60/waypoints/X1-RK60-AE9Z/jump-gate) has seven connections.
- One connected destination, [`X1-CM91-B17A`](https://api.spacetraders.io/v2/systems/X1-CM91/waypoints/X1-CM91-B17A), is likewise not under construction; its [`Construction` response](https://api.spacetraders.io/v2/systems/X1-CM91/waypoints/X1-CM91-B17A/construction) is complete, and its [`JumpGate` response](https://api.spacetraders.io/v2/systems/X1-CM91/waypoints/X1-CM91-B17A/jump-gate) links back to `X1-RK60-AE9Z`.

This is direct first-party evidence that the current universe contains a bidirectionally listed, complete gate pair for which no repair remains. It is **not** evidence of an authenticated ship jump or of permanence across resets.

## Material Uncertainty and Source Conflicts

1. **Warp reach is underspecified.** The contract requires a warp drive and fuel but gives no fuel-cost/range equation, maximum system distance, or semantics for module tiers. A real authenticated `warp-ship` attempt or additional first-party rule publication is needed to settle reach for a chosen target.
2. **Official prose examples are stale at the request-field level.** The navigation guide shows `systemSymbol` bodies for jump and warp, while the bundled v2.3.0 contract requires `waypointSymbol`. Use the bundled operation schemas. The guide remains useful only for high-level timing/fuel descriptions ([guide](https://docs.spacetraders.io/game-concepts/ship-navigation)).
3. **The official `ShipModule` model is internally stale for jump drives.** It lists `MODULE_JUMP_DRIVE_*`, but v2.1 release notes say those modules were removed and current `jump-ship` requires no module. Treat jump-drive symbols as model residue unless a current first-party API response proves availability.
4. **Antimatter failure details are not current-catalogue facts.** The bundled operation guarantees automatic purchase/consumption and a transaction, but it does not specify market stock, credit failure codes, or gate-market absence behavior. The docs’ legacy `ShipJumpMissingAntimatterError` is absent from the live v2.3.0 error catalogue.
5. **No authenticated arrival sample was gathered.** Public API responses establish current gate topology/completion, while arrival evidence above is derived from normative response and nav schemas. Exact cooldown duration, warp fuel consumed, and a concrete successful ship arrival remain target-, ship-, and reset-dependent observations.

## Sources

- Contract ground truth: `priv/spec/SpaceTraders.json`, v2.3.0, especially operation IDs `get-systems`, `get-system-waypoints`, `get-jump-gate`, `get-construction`, `supply-construction`, `orbit-ship`, `get-ship-cooldown`, `jump-ship`, `navigate-ship`, `get-ship-nav`, `warp-ship`, `refuel-ship`, `get-ship-modules`, `install-ship-module`, `get-market`, `get-shipyard`, and `purchase-ship`.
- [Official SpaceTraders navigation guide](https://docs.spacetraders.io/game-concepts/ship-navigation).
- [Official response-error catalogue page](https://docs.spacetraders.io/api-guide/response-errors) and [live first-party `/error-codes`](https://api.spacetraders.io/v2/error-codes).
- [Official v2.1 release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0).
- [Official OpenAPI model sources](https://github.com/SpaceTradersAPI/api-docs/tree/main/models).
- Reset-specific public API links cited under “Current First-Party Observations.”
