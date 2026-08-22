# Research: exploration and market mechanics for single-Ship automation

Research question: what facts in the current SpaceTraders API constrain single-Ship exploration, survey/chart behavior, market discovery and freshness, buying, selling, arbitrage, and directed procurement/delivery?

## Sources and confidence

- Contract ground truth is the repository's bundled `priv/spec/SpaceTraders.json`. Spec citations below name exact `operationId` and model schema names. The bundle references model schemas by name rather than embedding them.
- Current first-party behavior was checked only where the bundle does not settle the matter: the official [SpaceTraders status response](https://api.spacetraders.io/v2/), [official API documentation repository](https://github.com/SpaceTradersAPI/api-docs), and [official v2.1 release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0). Links to model files use the official repository's inspected commit, `45fbb04130aca3fa0bd9a634ab77b35fa6c468ab`, so citations remain stable.
- A statement labelled **not specified** is deliberately not filled from community knowledge. It is not safe to treat it as a server guarantee.

## Executive findings

1. Exploration data has three visibility levels. Public waypoint reads hide an uncharted waypoint's real traits; a sensor scan reveals traits to that scan's caller; charting publishes the real traits to all agents. Chart creation also returns the resulting `Chart`, `Waypoint`, and `Agent`, and grants a one-time rarity-based credit reward (`get-system-waypoints`, `get-waypoint`, `create-ship-waypoint-scan`, and `create-chart`; `Waypoint` and `Chart` schemas).
2. Market identity/composition and live trading data are different. Any caller can obtain exports, imports, and exchange goods at a marketplace, but `tradeGoods` price/supply rows and recent `transactions` are present only when a ship is at that market (`get-market`; `Market`, `MarketTradeGood`, and `MarketTransaction` schemas).
3. A price observation has no per-row observation timestamp. Transaction records do have timestamps. The live status response currently exposes a server-wide `health.lastMarketUpdate`, but that field is absent from the bundled `get-status` contract and is neither market-specific nor a promise that a previously observed market row remains current ([current official response](https://api.spacetraders.io/v2/)).
4. Buying and selling are immediate bounded transactions, not orders. They return updated agent/cargo state plus the executed transaction. `tradeVolume` is the maximum units of that good that can be bought or sold in one trade and also indicates price volatility (`purchase-cargo`, `sell-cargo`; `MarketTradeGood` and `MarketTransaction` schemas).
5. Surveying, scanning, extraction, siphoning, jumping, and refining consume the ship's shared reactor-action availability through cooldowns. A single Ship therefore cannot overlap those cooldown-gated actions, while market trades do not return or declare a cooldown (`create-survey`, scan operations, extraction operations, `siphon-resources`, `jump-ship`, `ship-refine`, and `get-ship-cooldown`; `Cooldown` schema).
6. Directed delivery has at least two distinct server semantics. Contract delivery updates contract progress and removes cargo; construction supply updates construction progress and removes cargo. Neither is a market sale and neither response includes credits or a market transaction (`deliver-contract`, `fulfill-contract`, `supply-construction`; `Contract`, `ContractTerms`, `ContractDeliverGood`, `Construction`, and `ConstructionMaterial` schemas).

## Ship state and capability constraints

`get-my-ship` returns the authoritative current `Ship` aggregate: navigation status/location, cooldown, installed modules and mounts, cargo, and fuel. `get-my-ship-cargo`, `get-ship-nav`, `get-ship-cooldown`, `get-mounts`, and `get-ship-modules` expose narrower current views. The `Ship` schema makes these parts explicit; the inspected official schema is [Ship.json](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Ship.json).

The relevant capability gates are:

| Action | Contract preconditions/capability | Resulting availability effect |
|---|---|---|
| Navigate within a system | Ship in orbit; destination in the same system; sufficient fuel implied by fuel consumption | Most actions unavailable until route arrival; response supplies route/arrival and remaining fuel (`navigate-ship`) |
| Warp between systems | Ship in orbit, Warp Drive module installed, and fuel for travel | Most actions unavailable until arrival (`warp-ship`) |
| Jump | Ship in orbit, destination connected; one unit of antimatter is purchased and consumed at market price | Returns cooldown, transaction, nav, and agent (`jump-ship`) |
| Scan systems/waypoints/ships | Sensor Array mount installed | Returns a cooldown (`create-ship-system-scan`, `create-ship-waypoint-scan`, `create-ship-ship-scan`) |
| Survey | Surveyor mount installed; current waypoint must be extractable | Returns surveys and a cooldown (`create-survey`) |
| Extract ore | Ship in orbit at an extractable waypoint and suitable mining equipment, such as a Mining Laser | Returns extraction yield, cargo, events, and cooldown (`extract-resources`) |
| Extract with survey | Full, unmodified survey payload whose signature validates | Returns extraction yield, cargo, events, and cooldown (`extract-resources-with-survey`) |
| Siphon | Ship in orbit, siphon mount, Gas Processor module, appropriate waypoint | Returns siphon yield, cargo, events, and cooldown (`siphon-resources`) |
| Buy/sell | Ship docked at a Marketplace and good traded there | No cooldown is specified or returned (`purchase-cargo`, `sell-cargo`) |
| Access market/shipyard surface functions | Ship docked | Docked ships cannot navigate/extract; orbiting ships cannot access market/shipyard (`dock-ship`, `orbit-ship`) |

The `ShipMount` schema identifies Surveyor, Sensor Array, Mining Laser, and Gas Siphon mount families and can include mount strength and producible deposits ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ShipMount.json)). The `ShipModule` schema identifies cargo holds, processors, refineries, and warp drives ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ShipModule.json)). Cargo capacity and occupied units are authoritative hard limits in `ShipCargo` ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ShipCargo.json)).

**Not specified:** `create-chart` says only that the Ship charts the waypoint at its current location. It declares no required nav status, mount/module, cooldown, or Ship condition. Do not assume that charting requires orbit, docking, or special equipment from this contract.

**Not specified:** `create-survey` does not explicitly say the Ship must be in orbit, although extraction does. Its guaranteed preconditions are an extractable current waypoint and a Surveyor mount.

## Waypoint discovery, scans, and charting

### Public and authoritative waypoint data

- `get-systems` returns all systems as pages. `get-system-waypoints` returns all waypoints in one system as pages and supports `type` and one-or-many `traits` filters. `get-waypoint` returns one waypoint.
- Both waypoint read operations substitute the `UNCHARTED` trait for actual traits while a waypoint is uncharted. Coordinates, type, system, orbitals, construction status, and the visible trait list are represented by `Waypoint`; the inspected schema is [Waypoint.json](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Waypoint.json).
- Therefore an uncharted public `Waypoint` is authoritative for the fields the API supplies but intentionally partial for traits. A trait filter cannot be assumed to discover a hidden real trait before charting because the operation says those traits are replaced.

### Scan visibility

`create-ship-waypoint-scan` returns nearby `ScannedWaypoint` objects and explicitly says scanning uncharted waypoints reveals their traits despite the uncharted state. It requires a Sensor Array mount and creates a cooldown. `ScannedWaypoint` contains symbol, type, system, coordinates, orbitals, faction, traits, and optional chart, but does not contain market prices or transactions ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ScannedWaypoint.json)). This is authoritative scan output for the caller, not a public chart.

### Chart effects and result

`create-chart`:

- acts on the Ship's current waypoint;
- replaces globally hidden traits with traits visible to all agents;
- records the submitting agent and submission time in `Chart`;
- gives a one-time credit reward based on trait rarity; and
- returns the created `chart`, newly visible `waypoint`, and updated `agent`.

The `Chart` schema is only attribution (`waypointSymbol`, `submittedBy`, `submittedOn`), not a snapshot of waypoint traits ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Chart.json)). The operation does not promise idempotence or define the response/error for attempting to chart an already charted waypoint, so repeated-chart behavior is materially unknown.

## Surveys and resource exploration

`create-survey` returns one or more complete `Survey` values plus cooldown. Each survey is tied to a waypoint symbol and contains a signed deposit list, expiration, and size. Duplicate deposit symbols increase that resource's extraction probability. Size (`SMALL`, `MODERATE`, `LARGE`) indicates how much can be extracted before exhaustion; surveys can be used by multiple ships and can end by expiration or exhaustion (`create-survey`; `Survey` schema, also [official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Survey.json)).

Survey extraction semantics are strict:

- Use `extract-resources-with-survey`; the survey property on `extract-resources` is deprecated.
- Send the entire survey object unchanged. The server validates its signature and rejects an invalid signature or changed property.
- A successful call returns the actual yield, updated cargo, cooldown, and condition events. The survey describes possible weighted deposits and improved quantity, not an exact promised yield.
- Expiration is an absolute date-time. Remaining uses are not exposed as a numeric field; only size is supplied. Exhaustion can therefore be learned only from successful/failing use, not calculated exactly from the schema.

The official v2.1 notes add reset-sensitive current-world context: individual asteroid waypoints can become `CRITICAL_LIMIT` and then `UNSTABLE` after excessive extraction, and yields vary by asteroid composition. The notes call the rough extraction rate a temporary assumption rather than a contract, so it must not be encoded as a fixed guarantee ([official release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)). Current waypoint modifiers are returned by extraction and represented by `Waypoint.modifiers`.

## Market discovery and visibility

### Locating markets

A marketplace is a waypoint with the `MARKETPLACE` trait. Once traits are visible, `get-system-waypoints` can filter by that trait. `get-market` requires such a waypoint but permits anonymous or Agent-token access.

The `Market` schema separates two data layers ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Market.json)):

| Always required | Present only with a ship at the market |
|---|---|
| `symbol`, `exports`, `imports`, `exchange` | `tradeGoods`, `transactions` |

The first layer identifies market composition. Its entries are `TradeGood` identity/name/description values, not prices. The second layer supplies current per-good type, trade volume, supply, optional activity, purchase price, and sell price (`MarketTradeGood`) plus recent executed transactions (`MarketTransaction`). Merely knowing a marketplace exists is therefore insufficient for price-based trading.

The phrase "ship is present at the market" in `get-market`/`Market` does not say docked; docking is explicitly required only for transacting. Presence is thus the contract requirement for full market observation, while docking is the contract requirement for purchase/sale.

### Freshness and authority

- A freshly returned `MarketTradeGood` row is the server's authoritative quoted market state in that response. It contains no timestamp or revision. The API does not define a validity duration.
- `MarketTransaction.timestamp` dates an executed transaction, not the adjacent quote. Its `type`, `units`, `pricePerUnit`, and `totalPrice` describe the actual execution (`MarketTransaction`; [official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/MarketTransaction.json)).
- The current unauthenticated status response includes `health.lastMarketUpdate`; this is useful evidence that markets update independently, but `health` is absent from bundled `get-status` and the timestamp is global rather than per market ([current official response](https://api.spacetraders.io/v2/)). It cannot establish quote freshness for one stored observation.
- The v2.1 notes state that starting-system market trade volume grows as players trade and that supply-chain bottlenecks/activity affect markets. This establishes that market state is dynamic and player activity matters, but it does not define an update interval or deterministic price formula ([official release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)).

## Buying, selling, and arbitrage constraints

### Buying

`purchase-cargo` requires the Ship docked at a Marketplace, the good sold there, sufficient cargo room, and implicitly enough agent credits. The requested units cannot exceed that good's `tradeVolume` for one transaction. Success returns updated `Agent`, updated `ShipCargo`, and a `MarketTransaction`; purchased units are in cargo.

### Selling

`sell-cargo` requires the Ship docked at a Marketplace, the market to trade that cargo, and the Ship to hold the requested units. Although the operation description does not repeat the bound, `MarketTradeGood.tradeVolume` explicitly defines the maximum units "purchased or sold" in one trade. Success returns updated `Agent`, updated `ShipCargo`, and a `MarketTransaction`.

Neither request's `units` field declares a positive minimum in the bundled operation schema. Valid zero/negative behavior is therefore **not specified** and should not be inferred from the successful response contract.

### Transaction meaning

- Purchase and sale are synchronous mutations returning the execution record. There is no order ID, pending state, quote reservation, partial-fill field, fee field, or cancellation operation in these contracts.
- `MarketTransaction.totalPrice` and `pricePerUnit` are authoritative execution values; updated `Agent.credits` and `ShipCargo` are authoritative post-transaction state.
- `tradeVolume` bounds each call, not total cargo moved over multiple calls. The contract does not promise that price, supply, activity, or trade volume remains unchanged after a call.
- `MarketTradeGood.supply` is one of `SCARCE`, `LIMITED`, `MODERATE`, `HIGH`, `ABUNDANT`. Optional `activity` is `WEAK`, `GROWING`, `STRONG`, or `RESTRICTED`; for imports it describes consumption strength and for exports production strength ([SupplyLevel](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/SupplyLevel.json), [ActivityLevel](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ActivityLevel.json)).

### What can be established for arbitrage

At observation time, the gross per-unit spread for moving a good is destination `sellPrice` minus source `purchasePrice`. A feasible movement is additionally bounded by source purchase `tradeVolume`, destination sale `tradeVolume`, free cargo capacity, available credits, fuel/range/navigation state, and whether both quote rows were visible with a Ship present (`MarketTradeGood`, `ShipCargo`, `ShipFuel`, `ShipNav`; `purchase-cargo`, `sell-cargo`, `navigate-ship`).

That comparison is evidence, not a locked opportunity: quotes have no timestamp/TTL and no reservation mechanism, both markets are dynamic, and only one Ship cannot be present at two markets simultaneously. The contract supplies no global market-price endpoint. `get-supply-chain` is reset-stable data describing which exports map to imports; it does not provide market locations or prices.

## Directed procurement and delivery

### Contract procurement/delivery

Contracts are agent-owned records. `get-contracts` is paginated; `get-contract` returns one authoritative contract. The `Contract`/`ContractTerms`/`ContractDeliverGood` chain provides:

- contract type, including `PROCUREMENT`;
- accepted and fulfilled state;
- acceptance deadline and fulfillment deadline;
- payment terms;
- each required `tradeSymbol`, `destinationSymbol`, `unitsRequired`, and `unitsFulfilled`.

See the exact `Contract`, `ContractTerms`, and `ContractDeliverGood` schemas ([Contract](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Contract.json), [terms](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ContractTerms.json), [delivery good](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ContractDeliverGood.json)).

`accept-contract` succeeds only for an offered, not-yet-accepted contract before its acceptance deadline. `deliver-contract` requires the named Ship at the delivery waypoint and the required good in cargo; it removes delivered cargo and returns updated contract and cargo. It does **not** require docking in its operation contract. Deliveries can be incremental because progress is represented by `unitsFulfilled`, but the request must identify units for one required good. `fulfill-contract` is a separate operation available only after all delivery terms are fulfilled; that response returns updated agent and contract, which is where the fulfillment payment/state mutation is represented.

`negotiateContract` requires the Ship at a waypoint with a faction and currently limits the agent to one ongoing/offered contract. Negotiation creates an offer; it does not accept it.

### Construction procurement/delivery

`get-construction` requires `Waypoint.isUnderConstruction == true` and returns the site's exact materials and completion state. Every `ConstructionMaterial` supplies `tradeSymbol`, `required`, and `fulfilled` ([Construction](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Construction.json), [ConstructionMaterial](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/ConstructionMaterial.json)).

`supply-construction` requires an under-construction waypoint and the specified good in the named Ship's cargo. Success removes cargo and returns updated `Construction` plus `ShipCargo`. The bundled contract does **not** explicitly say the Ship must be at the construction waypoint, docked, or in orbit, and it does not state over-delivery behavior. Those are material unknowns, not safe preconditions to invent. The v2.1 notes say jump gates are presently the construction sites and that agents supply their materials, but this is mutable alpha behavior rather than a permanent type restriction ([official release notes](https://github.com/SpaceTradersAPI/api-docs/releases/tag/v2.1.0)).

## Pagination

The exploration/procurement list operations `get-systems`, `get-system-waypoints`, `get-my-ships`, and `get-contracts` all use `page` (minimum 1, default 1) and `limit` (minimum 1, maximum 20, default 10) and return `Meta`. `Meta.total`, `Meta.page`, and `Meta.limit` define completion; one response is not an exhaustive list unless its metadata says so ([official `Meta` schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Meta.json)). Single-resource market, waypoint, contract, construction, and Ship reads are not paginated. Scan and survey action result arrays have no pagination metadata and are the complete result of that action response.

## Cooldowns and temporal boundaries

`get-ship-cooldown` states that scanning, extraction, and jump-like reactor actions prevent additional actions until cooldown expiry; duration depends on the relevant mount/module power consumption. It returns `204 No Content` when there is no cooldown. `Cooldown` supplies `totalSeconds`, `remainingSeconds`, and optional absolute `expiration` ([official schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/models/Cooldown.json)).

Navigation transit is a separate temporal gate represented by `ShipNav.status` and route arrival, not by reactor cooldown. Survey expiration is another independent absolute deadline. Contract acceptance and fulfillment deadlines and server reset time are additional independent deadlines.

## Reset sensitivity

- Agent bearer tokens are valid only for a specific reset (`AgentToken` security scheme). The bundled `get-status` returns last `resetDate` and `serverResets.next`/`frequency`.
- The official live response observed during this research reports API `v2.3.0`, reset date `2026-08-16`, next reset `2026-08-23T13:00:00.000Z`, and weekly frequency. Its announcement says old access tokens become invalid and agents must re-register after a complete reset ([current official response](https://api.spacetraders.io/v2/)). These values are live observations, not constants.
- The spec's `Data` tag says Data endpoints do not change during a reset but may change between resets. `get-supply-chain` is a Data endpoint. Systems, waypoints/charts, markets, surveys, contracts, cargo, credits, and construction are not labelled reset-stable by that guarantee.
- Consequently symbols, topology, charts, market observations, contract/construction progress, Ship state, and credentials must all be treated as reset-scoped unless a stronger endpoint contract says otherwise. The bundle supplies no durable cross-reset identity for those records.

## Material uncertainties left by primary sources

1. Chart preconditions beyond "Ship at current waypoint," and the exact already-charted response/reward behavior, are unspecified.
2. Survey nav-status precondition is unspecified; survey remaining uses are not enumerable, and exact exhaustion amounts/timing are not exposed.
3. Market quote observation time, quote TTL, update cadence, price-impact formula, recent-transaction retention/count, and whether repeated calls can transact at one observed quote are unspecified. The live global market-update timestamp does not answer these per-market questions.
4. Construction supply does not contractually state Ship location/nav status or over-delivery behavior. Contract delivery states location but not dock/orbit status or over-delivery behavior.
5. The exact API errors for insufficient credits/cargo space, zero or negative units, stale trade volume, expired/exhausted surveys, and deadline/reset races are outside the successful-response contract inspected here and require authorized live probes to settle.

## Map-ready gist

A single Ship can discover hidden traits by cooldown-gated sensor scan and publish them by charting, but full market quotes require physical presence and trades require docking; quotes are dynamic, untimestamped, trade-volume-bounded executions, while contract and construction deliveries consume cargo through separate progress APIs with reset-scoped state.
