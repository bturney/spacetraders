# Complete API and Leaderboard Surface

Research for [#300](https://github.com/bturney/spacetraders/issues/300), part
of the [Phase 4+ map #297](https://github.com/bturney/spacetraders/issues/297),
2026-09-10. This is an inventory of external mechanics, not a design for an
application capability, Policy, Intent, or coordination model.

## Executive Answer

The bundled SpaceTraders v2.3.0 OpenAPI contract contains **59 operations on
55 paths: 33 mutating operations and 26 read operations**. The 33 mutations
span registration, Construction, Contracts, fleet acquisition and posture,
resource gathering and conversion, movement, trade and Cargo transfer,
Contract negotiation, outfitting, maintenance, and scrapping. The inventories
below account for every `operationId` in the contract. [Contract identity and
purpose](../../priv/spec/SpaceTraders.json#L1-L26); [first operation](../../priv/spec/SpaceTraders.json#L78-L245);
[last operation](../../priv/spec/SpaceTraders.json#L3695-L3784).

Only two official leaderboard categories exist in the contract and current
first-party API response: **most credits** (`agentSymbol`, `credits`) and **most
submitted charts** (`agentSymbol`, `chartCount`). Public Agent reads also make
current credits and Ship count measurable for every enumerated Agent, but Ship
count is not an official leaderboard category. The API exposes neither ranks
beyond the returned arrays nor history, reset-final standings, rates, profit,
net worth, Contract/Construction contribution, or per-Ship production. [Status
schema](../../priv/spec/SpaceTraders.json#L132-L174); [Agent model](../../priv/spec/models/Agent.json#L10-L36);
[public Agent operations](../../priv/spec/SpaceTraders.json#L1013-L1116).

The autonomous target must account for five shared coordination surfaces even
though this report does not design how: Agent credits and Fleet ownership,
Agent-wide Contracts, shared world Markets, shared Construction progress, and
Surveys/charts whose use or effect crosses Ships and Agents. A sixth resource,
the API request budget, is shared at IP-address and Account scope. [Agent
model](../../priv/spec/models/Agent.json#L21-L36); [Contract operations](../../priv/spec/SpaceTraders.json#L1118-L1399);
[Market model](../../priv/spec/models/Market.json#L9-L45); [Construction model](../../priv/spec/models/Construction.json#L9-L21);
[Survey operation](../../priv/spec/SpaceTraders.json#L1915-L1968); [official
rate limits](https://docs.spacetraders.io/api-guide/rate-limits#rate-limits).

## Source Classification and Boundaries

| Classification | Meaning here |
| --- | --- |
| **Contract fact** | Stated by the checked-in v2.3.0 OpenAPI document or one of its referenced models. This is the repository's contract ground truth. [Spec identity](../../priv/spec/SpaceTraders.json#L1-L6) |
| **Current first-party documentation** | SpaceTraders-owned explanatory documentation, consulted where the contract is silent. Its current mechanic statements are cited by page anchors. |
| **Live observation** | A timestamped unauthenticated response from the first-party `GET https://api.spacetraders.io/v2` endpoint, with the relevant payload captured below. It describes the current reset, not a durable contract promise. [Contracted status endpoint](../../priv/spec/SpaceTraders.json#L78-L245) |
| **Unknown** | Not settled by the bundled contract or current first-party source. It must not be inferred from likely game behavior. |

The official GitHub OpenAPI source was also checked at commit
[`45fbb041`](https://github.com/SpaceTradersAPI/api-docs/commit/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab)
(2025-04-27 UTC). It matches the checked-in v2.3.0 operation surface. The
bundled copy remains authoritative for this report.

## Complete Mutating Surface

**Table key.** "Evidence" is the successful response state that authoritatively
proves what the call changed. "Wait/shared/irreversible" identifies an async
gate, resource visible to other work, or consequence with no inverse endpoint.
"Failure boundary" lists material preconditions to re-observe after rejection
or an ambiguous transport result; it does not assert undocumented error-code
mappings. Except for `orbit-ship` and `dock-ship`, which explicitly promise
idempotence, the contract does not declare mutation idempotency. Therefore a
lost success response is uncertain until the corresponding read surface is
reconciled. [Orbit](../../priv/spec/SpaceTraders.json#L1610-L1658); [dock](../../priv/spec/SpaceTraders.json#L1865-L1913).

### Identity, World Projects, and Contracts

| Mutation | Required observations and prerequisites | Evidence | Wait/shared/irreversible and failure boundary |
| --- | --- | --- | --- |
| `POST /register` (`register`) | AccountToken; unique 3-14 character symbol; starting faction; optional reserved-call-sign email. | `201` returns AgentToken, Agent, Faction, starting Contract, and Ships. | Creates the reset-scoped Agent identity and initial Fleet; no deregistration operation. Rejection boundaries include AccountToken, symbol/faction validity and uniqueness. The response schema says required `ship` while the property is `ships`, a contract defect. [Operation](../../priv/spec/SpaceTraders.json#L247-L325) |
| `POST .../construction/supply` (`supply-construction`) | Construction Waypoint still under construction; supplying Ship, Trade Good, units, and matching Cargo. The contract does not state where the Ship must be, so any location prerequisite remains unknown and API-enforced. | Updated Construction and supplying Ship Cargo. | Irreversibly removes Cargo into globally shared Construction progress; oversupply/completion races are material. [Operation](../../priv/spec/SpaceTraders.json#L796-L880); [materials](../../priv/spec/models/ConstructionMaterial.json#L1-L18) |
| `POST /my/contracts/{id}/accept` (`accept-contract`) | Offered, unaccepted Contract before `deadlineToAccept`; observe current Contract. | Updated Contract (`accepted`) and Agent (acceptance credits). | Commits one of the Agent's Contract slots; the contract exposes no abandon/reject mutation. Expired/already accepted/not offered are re-observation boundaries. [Operation](../../priv/spec/SpaceTraders.json#L1221-L1270); [Contract state](../../priv/spec/models/Contract.json#L23-L45) |
| `POST /my/contracts/{id}/deliver` (`deliver-contract`) | Ship at required `destinationSymbol`, matching Cargo and units, current outstanding deliverable. | Updated Contract and that Ship's Cargo. | Irreversibly consumes Cargo into Agent-wide Contract progress; multiple Ships can target the same remaining requirement, so stale outstanding units race. [Operation](../../priv/spec/SpaceTraders.json#L1272-L1347); [deliverable fields](../../priv/spec/models/ContractDeliverGood.json#L1-L25) |
| `POST /my/contracts/{id}/fulfill` (`fulfill-contract`) | All delivery terms fulfilled before Contract deadline; re-read Contract. | Updated fulfilled Contract and Agent (fulfillment credits). | Finalizes the Contract; premature, expired, or already fulfilled state requires reconciliation. [Operation](../../priv/spec/SpaceTraders.json#L1349-L1399); [terms](../../priv/spec/models/ContractTerms.json#L1-L22) |

### Fleet, Posture, Resources, and Cargo

| Mutation | Required observations and prerequisites | Evidence | Wait/shared/irreversible and failure boundary |
| --- | --- | --- | --- |
| `POST /my/ships` (`purchase-ship`) | Current credits; Shipyard offer for type and price; an owned Ship present at that Shipyard Waypoint. | Updated Agent, new complete Ship, Shipyard transaction. | Spends shared credits and permanently adds a Ship (only inverse is value-losing scrap). Offer/price/presence and credits can stale. [Operation](../../priv/spec/SpaceTraders.json#L1461-L1522); [Shipyard listing](../../priv/spec/models/Shipyard.json#L10-L42) |
| `POST .../orbit` (`orbit-ship`) | Ship able to change posture and not in transit; no body. | Updated Nav with `IN_ORBIT`. | Idempotent. Enables above-surface actions but disables Market/Shipyard access. [Operation](../../priv/spec/SpaceTraders.json#L1610-L1658) |
| `POST .../dock` (`dock-ship`) | Ship able to dock and not in transit; no body. | Updated Nav with `DOCKED`. | Idempotent. Enables local Market/Shipyard access but disables navigation/extraction. [Operation](../../priv/spec/SpaceTraders.json#L1865-L1913) |
| `POST .../refine` (`ship-refine`) | `produce`; compatible Refinery module; at least 100 refinable basic goods and resulting Cargo room. | Cargo, cooldown, exact `consumed` and `produced` arrays. | Irreversibly converts 100 basic goods to 10 processed goods and starts a Ship cooldown. Re-observe Cargo/modules/cooldown. [Operation](../../priv/spec/SpaceTraders.json#L1660-L1763) |
| `POST .../chart` (`create-chart`) | Ship at the Waypoint; its chart status/provenance. | Chart, newly visible Waypoint facts, updated Agent credits. | Globally reveals traits, records the first charting Agent, pays a one-time rarity reward, and contributes to the charts leaderboard; already-charted state is not reversible. [Operation](../../priv/spec/SpaceTraders.json#L1765-L1817); [official charting](https://docs.spacetraders.io/game-concepts/exploration#charting) |
| `POST .../survey` (`create-survey`) | Ship in orbit at an extractable Waypoint, compatible Surveyor mount, and no active cooldown. Orbit is named by the official error catalogue rather than the operation prose. | New Surveys and cooldown. | Starts cooldown. Surveys can be shared by multiple Ships, expire, and become exhausted; changing any field invalidates the signed payload. [Operation](../../priv/spec/SpaceTraders.json#L1915-L1968); [Survey model](../../priv/spec/models/Survey.json#L1-L34); [official Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) |
| `POST .../extract` (`extract-resources`) | Ship in orbit at an extractable Waypoint; compatible extraction mount and mineral processor for mineral extraction; Cargo room; ready cooldown. The optional Survey payload is deprecated in favor of the separate Survey extraction operation. | Extraction Yield, Cargo, cooldown, condition events, optional Waypoint Modifiers. | Starts cooldown, fills Cargo, may degrade Ship components, and may change shared Waypoint modifiers. Exhaustion/capacity/capability/cooldown/modifier state are observable failure boundaries. [Operation](../../priv/spec/SpaceTraders.json#L1970-L2050); [official extraction](https://docs.spacetraders.io/game-concepts/extracting-resources#extracting-resources); [official Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) |
| `POST .../siphon` (`siphon-resources`) | Ship in orbit at a gas source; siphon mount plus gas processor; Cargo room; ready cooldown. | Siphon Yield, Cargo, cooldown, condition events. | Starts cooldown, fills Cargo, and may degrade components. Re-observe capability, Cargo, cooldown, and location. [Operation](../../priv/spec/SpaceTraders.json#L2052-L2111); [official siphoning](https://docs.spacetraders.io/game-concepts/extracting-resources#siphoning-resources) |
| `POST .../extract/survey` (`extract-resources-with-survey`) | Same extraction readiness, including the mineral processor requirement named by the official error catalogue, plus the exact full, matching, unexpired, unexhausted Survey object. | Extraction Yield, Cargo, cooldown, condition events. | Starts cooldown, fills Cargo, may degrade components, and consumes finite Survey usefulness. Altered Survey data invalidates the signature; expiration and exhaustion are distinct observable failures. [Operation](../../priv/spec/SpaceTraders.json#L2113-L2181); [official Survey lifetime](https://docs.spacetraders.io/game-concepts/extracting-resources#surveying); [official Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) |
| `POST .../jettison` (`jettison`) | Trade Good symbol and positive units present in that Ship's Cargo. | Updated Cargo. | Irreversibly destroys selected Cargo; absent/insufficient Cargo is the principal boundary. [Operation](../../priv/spec/SpaceTraders.json#L2183-L2250) |
| `POST .../sell` (`sell-cargo`) | Ship docked at a Marketplace that currently trades the Cargo symbol; units in Cargo; fresh on-site Market listing. | Updated Agent credits, Cargo, Market transaction. | Removes Cargo, changes shared credits, and participates in a player-driven shared Market. Listing, price, trade volume, Cargo, or posture can stale. [Operation](../../priv/spec/SpaceTraders.json#L2583-L2657); [official market behavior](https://docs.spacetraders.io/game-concepts/markets#overview) |
| `POST .../refuel` (`refuel-ship`) | Ship docked at a Marketplace selling fuel; `fromCargo` selects Cargo as the fuel source but the contract does not relax the docking/Marketplace prerequisite. Optional units are Ship-fuel units, not Market units. Observe fuel capacity, credits/Cargo, and listing. | Agent, fuel, transaction, and optional updated Cargo. | Spends shared credits or consumes Cargo. Contract prose says always fill to maximum, while the request schema permits a partial `units` amount: actual response is authoritative. [Operation](../../priv/spec/SpaceTraders.json#L2824-L2902) |
| `POST .../purchase` (`purchase-cargo`) | Ship docked at Marketplace selling symbol; fresh on-site price/supply/trade volume; Cargo room and shared credits; units no greater than transaction `tradeVolume`. | Updated Agent credits, Cargo, Market transaction. | Spends credits and changes the shared Market. Price, supply, volume, Cargo, and credits race other work. [Operation](../../priv/spec/SpaceTraders.json#L2904-L2978); [Market visibility](../../priv/spec/models/Market.json#L30-L45) |
| `POST .../transfer` (`transfer-cargo`) | Distinct sending and receiving Ships owned by the same Agent, at the same Waypoint and in the same posture; sender has units; receiver has Cargo room. Same-Ship and cross-Agent conflicts are named by the official error catalogue rather than the operation prose. | **Only sender Cargo** is returned. | Cross-Ship atomic Cargo movement. A receiver read is the available full confirmation after ambiguity; location/posture/capacity and sender inventory can race. [Operation](../../priv/spec/SpaceTraders.json#L2980-L3051); [official Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) |

### Movement and Scanning

| Mutation | Required observations and prerequisites | Evidence | Wait/shared/irreversible and failure boundary |
| --- | --- | --- | --- |
| `POST .../jump` (`jump-ship`) | Ship in orbit; destination connected by Jump Gate; current credits and Market antimatter price; ready cooldown. | Updated Nav, cooldown, Agent credits, and antimatter Market transaction. | Arrival is instant, but one antimatter unit is bought/consumed and a cooldown starts. Connectivity, credits/price, posture, and cooldown can stale. [Operation](../../priv/spec/SpaceTraders.json#L2252-L2324) |
| `POST .../navigate` (`navigate-ship`) | Ship in orbit; destination in current System; enough fuel; not already in transit. Flight mode controls speed/fuel. | Nav route with Arrival, updated fuel, condition events. | Fuel is consumed and Ship enters `IN_TRANSIT`; most actions wait until Arrival. Movement may degrade components. [Operation](../../priv/spec/SpaceTraders.json#L2326-L2399); [Nav model](../../priv/spec/models/ShipNav.json#L1-L22) |
| `PATCH .../nav` (`patch-ship-nav`) | Ship Nav and requested `flightMode`; the request schema incorrectly marks no field required. | Updated Nav, fuel, condition events. | Changes future speed/fuel posture; returned events/fuel mean the response, not a local assignment, is authoritative. Valid mode/current transit eligibility are failure boundaries. [Operation](../../priv/spec/SpaceTraders.json#L2401-L2471) |
| `POST .../warp` (`warp-ship`) | Ship in orbit; Warp Drive installed; inter-System target and enough fuel; not in transit. | Nav route with Arrival and updated fuel. | Fuel is consumed and Ship enters transit; most actions wait until Arrival. No cooldown is returned. [Operation](../../priv/spec/SpaceTraders.json#L2514-L2581) |
| `POST .../scan/systems` (`create-ship-system-scan`) | Sensor Array mount and ready Ship cooldown; exact posture/range rules are not stated. | Scanned Systems and cooldown. | Starts cooldown and yields point-in-time Operational Intelligence. Re-observe mount/cooldown; undocumented posture/range remain API-enforced. [Operation](../../priv/spec/SpaceTraders.json#L2659-L2712) |
| `POST .../scan/waypoints` (`create-ship-waypoint-scan`) | Sensor Array mount and ready cooldown; exact posture/range rules are not stated. | Scanned Waypoints, including traits hidden by uncharted public reads, and cooldown. | Starts cooldown; observations can stale and do not globally chart. [Operation](../../priv/spec/SpaceTraders.json#L2714-L2767) |
| `POST .../scan/ships` (`create-ship-ship-scan`) | Sensor Array mount and ready cooldown; exact posture/range rules are not stated. | nearby Scanned Ships and cooldown. | Starts cooldown; other-Agent Ship observations are point-in-time only. [Operation](../../priv/spec/SpaceTraders.json#L2769-L2822) |

### Contracts, Outfitting, and Maintenance

| Mutation | Required observations and prerequisites | Evidence | Wait/shared/irreversible and failure boundary |
| --- | --- | --- | --- |
| `POST .../negotiate/contract` (`negotiateContract`) | Ship at any Waypoint with a faction; Agent below the current maximum of one ongoing or offered Contract. | Newly offered Contract. | Consumes Agent-wide Contract availability until accepted/resolved/expired. Faction presence and Contract count can stale. [Operation](../../priv/spec/SpaceTraders.json#L3053-L3101) |
| `POST .../mounts/install` (`install-mount`) | Ship docked at Shipyard; selected mount in that Ship's Cargo; slots/power/crew compatibility; modification fee credits. | Agent, installed mounts, Cargo, modification transaction. | Spends shared credits and consumes Cargo item; inverse removal also costs and needs Cargo room. [Operation](../../priv/spec/SpaceTraders.json#L3150-L3226); [requirements](../../priv/spec/models/ShipRequirements.json#L1-L18) |
| `POST .../mounts/remove` (`remove-mount`) | Ship docked at Shipyard; mount installed; modification fee credits and Cargo room. | Agent, installed mounts, Cargo, modification transaction. | Spends credits, places mount in Cargo, and can remove capability. [Operation](../../priv/spec/SpaceTraders.json#L3228-L3305) |
| `POST .../modules/install` (`install-ship-module`) | Module in same Ship's Cargo; slots/power/crew compatibility and likely modification context/fee. **Contract does not state docking or Shipyard precondition.** The operation also omits a security override and therefore inherits the malformed global OpenAPI requirement for both AgentToken and AccountToken; live authorization behavior is unknown. | Agent, modules, Cargo, modification transaction. | Spends returned transaction price, consumes Cargo item, changes capability/capacity. Exact legal location is unknown despite Shipyard's module fee. [Operation](../../priv/spec/SpaceTraders.json#L3606-L3693); [global security](../../priv/spec/SpaceTraders.json#L16-L20); [Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L42) |
| `POST .../modules/remove` (`remove-ship-module`) | Module installed; Cargo room; likely modification context/fee. **Contract does not state docking or Shipyard precondition.** It likewise inherits the malformed global two-token requirement because it has no security override; live authorization behavior is unknown. | Agent, modules, Cargo, modification transaction. | Spends returned transaction price, places module in Cargo, can remove capability/capacity. Behavior when reduced capacity would be exceeded is unknown. [Operation](../../priv/spec/SpaceTraders.json#L3695-L3784); [global security](../../priv/spec/SpaceTraders.json#L16-L20) |
| `POST .../repair` (`repair-ship`, preview) | Ship docked at Shipyard; current GET repair quote and shared credits. | Updated Agent, complete Ship, Repair transaction. | Restores component condition to 1 but current official docs say every repair permanently reduces integrity slightly; quote can stale with parts/plating prices. [Operation](../../priv/spec/SpaceTraders.json#L3408-L3510); [official repair semantics](https://docs.spacetraders.io/game-concepts/maintenance#ship-repair) |
| `POST .../scrap` (`scrap-ship`, preview) | Ship docked at Shipyard; current GET scrap quote; remove anything to retain first. | Updated Agent and Scrap transaction; absence must be reconciled through Fleet reads after ambiguity. | Irreversibly removes Ship. Official docs say Cargo is destroyed and not valued; mounts/modules receive poor value. [Operation](../../priv/spec/SpaceTraders.json#L3307-L3406); [official scrapping](https://docs.spacetraders.io/game-concepts/maintenance#scrapping) |

## Complete Observation Surface

These are all 26 contract `GET` operations. Paginated collection endpoints use
`page` and `limit`; the contract's maximum page size is 20. A complete
observation requires following `Meta` rather than treating one page as the
whole set. [Systems pagination](../../priv/spec/SpaceTraders.json#L328-L390);
[Meta](../../priv/spec/models/Meta.json#L1-L29).

| Scope | Read operation(s) | Authoritative observation and visibility boundary |
| --- | --- | --- |
| Global | `get-status`: `GET /` | Status/version, last reset date, aggregate stats, two leaderboards, next/frequency, announcements, links; public. [Contract](../../priv/spec/SpaceTraders.json#L78-L245) |
| Systems | `get-systems`: `GET /systems`; `get-system`: `GET /systems/{system}` | Paginated complete Systems or one System; public/AgentToken alternatives. [Contract](../../priv/spec/SpaceTraders.json#L328-L434) |
| Waypoints | `get-system-waypoints`: `GET .../waypoints`; `get-waypoint`: `GET .../waypoints/{waypoint}` | Identity, coordinates, orbitals, traits, modifiers, chart, faction and Construction flag. Uncharted reads substitute `UNCHARTED` for real traits; list supports type/trait filters. [Contract](../../priv/spec/SpaceTraders.json#L435-L582); [Waypoint](../../priv/spec/models/Waypoint.json#L1-L62) |
| Market | `get-market`: `GET .../market` | Imports/exports/exchange are remote composition; live `tradeGoods` prices/supply/activity/volume and recent transactions require Ship presence. [Contract](../../priv/spec/SpaceTraders.json#L585-L635); [Market](../../priv/spec/models/Market.json#L1-L46) |
| Shipyard | `get-shipyard`: `GET .../shipyard` | Ship types and modification fee; current Ship offers and transactions require Ship presence. [Contract](../../priv/spec/SpaceTraders.json#L637-L688); [Shipyard](../../priv/spec/models/Shipyard.json#L1-L43) |
| Jump Gate | `get-jump-gate`: `GET .../jump-gate` | Connections from a `JUMP_GATE` Waypoint. Contract description is truncated, so it establishes no extra discovery rule. [Contract](../../priv/spec/SpaceTraders.json#L690-L741) |
| Construction | `get-construction`: `GET .../construction` | Current materials (`required`, `fulfilled`) and `isComplete` for a Waypoint under construction. [Contract](../../priv/spec/SpaceTraders.json#L743-L794); [model](../../priv/spec/models/Construction.json#L1-L22) |
| Factions | `get-factions`: `GET /factions`; `get-faction`: `GET /factions/{symbol}` | Paginated all Factions or one Faction, including headquarters, traits and recruitment state. [Contract](../../priv/spec/SpaceTraders.json#L882-L979); [Faction](../../priv/spec/models/Faction.json#L1-L42) |
| Own Agent | `get-my-agent`: `GET /my/agent` | Current own Agent, including Account ID where supplied, headquarters, credits, faction, Ship count. [Contract](../../priv/spec/SpaceTraders.json#L981-L1011); [Agent](../../priv/spec/models/Agent.json#L1-L37) |
| Public Agents | `get-agents`: `GET /agents`; `get-agent`: `GET /agents/{symbol}` | Paginated Agents or one Agent: symbol, headquarters, credits, faction, Ship count; no Account ID promised publicly. [Contract](../../priv/spec/SpaceTraders.json#L1013-L1116); [Agent](../../priv/spec/models/Agent.json#L5-L36) |
| Contracts | `get-contracts`: `GET /my/contracts`; `get-contract`: `GET /my/contracts/{id}` | Paginated Agent Contracts or one Contract, including acceptance/fulfillment, deadlines, payments, and delivery progress. [Contract](../../priv/spec/SpaceTraders.json#L1118-L1219); [Contract](../../priv/spec/models/Contract.json#L1-L46) |
| Fleet | `get-my-ships`: `GET /my/ships`; `get-my-ship`: `GET /my/ships/{symbol}` | Paginated complete Fleet or one complete Ship: Nav, crew, frame/reactor/engine, cooldown, modules, mounts, Cargo, fuel. [Contract](../../priv/spec/SpaceTraders.json#L1401-L1565); [Ship](../../priv/spec/models/Ship.json#L1-L65) |
| Ship partials | `get-my-ship-cargo`, `get-ship-nav`, `get-mounts`, `get-ship-modules` | Current Cargo; Nav/Arrival/flight mode; installed mounts; installed modules. Module GET has no operation-level security declaration and therefore inherits the contract's unusual global security object. [Cargo](../../priv/spec/SpaceTraders.json#L1567-L1608); [Nav](../../priv/spec/SpaceTraders.json#L2472-L2512); [mounts](../../priv/spec/SpaceTraders.json#L3103-L3148); [modules](../../priv/spec/SpaceTraders.json#L3566-L3604) |
| Cooldown | `get-ship-cooldown`: `GET .../cooldown` | `200` Cooldown with remaining/expiration or `204` when none. This is the explicit wait observation. [Contract](../../priv/spec/SpaceTraders.json#L1819-L1864); [Cooldown](../../priv/spec/models/Cooldown.json#L1-L27) |
| Maintenance quotes | `get-scrap-ship`, `get-repair-ship`: `GET .../scrap`, `GET .../repair` | Current preview Scrap earnings or Repair cost transaction. Both are marked preview features. [Contract](../../priv/spec/SpaceTraders.json#L3307-L3456) |
| Supply chain | `get-supply-chain`: `GET /market/supply-chain` | Reset-static export-to-import mapping, authenticated per operation. It is a relationship map, not live listing/price evidence. [Contract](../../priv/spec/SpaceTraders.json#L3512-L3564) |

Three mutation responses are also observation-only in their gameplay effect:
the three scan operations return nearby Systems, Waypoints, or Ships while
mutating only the scanning Ship's cooldown. `create-chart` both observes and
globally mutates chart state. They remain in the mutating inventory because
they are POSTs with durable game effects.

## Async and Temporal Surface

| Time boundary | Contract fact and required evidence |
| --- | --- |
| Ship transit | Navigate and Warp return a route with Arrival and make most actions unavailable until then. Nav `status`/route, not elapsed local time alone, is authoritative. [Navigate](../../priv/spec/SpaceTraders.json#L2326-L2379); [Warp](../../priv/spec/SpaceTraders.json#L2514-L2560); [route](../../priv/spec/models/ShipNavRoute.json#L1-L24) |
| Ship cooldown | Refine, survey, extract, siphon, Jump, and all three scans return a Cooldown. `GET .../cooldown` returns 204 when absent. Official extraction docs clarify that navigation remains possible during cooldown while most other Ship actions do not. [Cooldown endpoint](../../priv/spec/SpaceTraders.json#L1819-L1843); [official extraction](https://docs.spacetraders.io/game-concepts/extracting-resources#extracting-resources) |
| Survey lifetime | Every Survey has an expiration and finite size; the full signed Survey is validated at extraction. Expiration/exhaustion are authoritative failure boundaries. [Survey](../../priv/spec/models/Survey.json#L5-L33); [survey extraction](../../priv/spec/SpaceTraders.json#L2113-L2161) |
| Contract time | `deadlineToAccept` gates acceptance; `terms.deadline` gates completion. The old `expiration` field is deprecated. [Contract](../../priv/spec/models/Contract.json#L33-L45); [terms](../../priv/spec/models/ContractTerms.json#L5-L21) |
| Reset time | Status returns last `resetDate` and intended next reset/frequency. Current docs say resets occur every 7 or 14 days and exact time belongs to status; live data, not that cadence prose, is authoritative for the next reset. [Status](../../priv/spec/SpaceTraders.json#L99-L102); [schedule fields](../../priv/spec/SpaceTraders.json#L175-L188); [official reset docs](https://docs.spacetraders.io/server-resets) |

No operation declares an idempotency key, request identifier, conditional
write, version/ETag, reservation, transaction grouping, or cancellation
surface. The contract exposes no mutation to interrupt transit or cooldown.
Consequently, the API surface itself provides state reconciliation, not a
generic exactly-once guarantee. This is an inventory-level omission, not an
application design conclusion.

## Shared Resources and Coordination Mechanics

| Shared surface | Owning API facts | Coordination pressure established by the source |
| --- | --- | --- |
| Agent credits and Fleet | Credits and Ship count live on one Agent. Purchases, trades, refueling, Jump, modification, repair, scrap, and Contract payments return updated Agent state. [Agent](../../priv/spec/models/Agent.json#L21-L36); [purchase Ship](../../priv/spec/SpaceTraders.json#L1483-L1511) | Concurrent Ships spend or earn one balance; stale affordability is not authoritative. Credits are also an official leaderboard measurement. |
| Per-Ship exclusivity | Complete Ship state includes Nav, cooldown, capability, Cargo and fuel. Transit/cooldown/posture gate action eligibility. [Ship](../../priv/spec/models/Ship.json#L9-L64) | One Ship cannot independently satisfy incompatible posture, location, transit, cooldown, capacity, fuel, or component requirements at the same instant. |
| Agent Contracts | Contract list belongs to the Agent; current negotiation cap is one offered/ongoing Contract; deliveries name any qualifying Ship. [Negotiation](../../priv/spec/SpaceTraders.json#L3053-L3056); [delivery](../../priv/spec/SpaceTraders.json#L1272-L1318) | Ships share slot, deadline, deliverables and staged rewards; deliveries can race the same outstanding units. |
| Markets | On-site live listings and recent transactions are visibility-gated. Current official docs state supply/demand and prices respond to Agent activity. [Market](../../priv/spec/models/Market.json#L30-L45); [official market behavior](https://docs.spacetraders.io/game-concepts/markets#exports) | Fleet and other Agents can alter the price/supply observed by a planned trade; only a fresh on-site listing plus mutation response settles execution. |
| Construction | Construction materials expose globally accumulated `fulfilled` units and one completion flag; supplying returns updated global progress plus local Cargo. [Construction](../../priv/spec/models/Construction.json#L9-L21); [supply](../../priv/spec/SpaceTraders.json#L796-L850) | Multiple Ships and Agents can fulfill the same remaining material while a delivery is being prepared. |
| Surveys | Survey operation explicitly permits multiple Ships to use one Survey; Survey has signed identity, expiration and finite size. [Operation](../../priv/spec/SpaceTraders.json#L1915-L1918); [Survey](../../priv/spec/models/Survey.json#L5-L33) | Survey usefulness is shared, expiring Operational Intelligence; extraction can discover exhaustion. |
| Charts | Charting globally reveals Waypoint traits, records one charting Agent, pays once, and increments an official leaderboard measurement. [Chart operation](../../priv/spec/SpaceTraders.json#L1765-L1797); [leaderboard](../../priv/spec/SpaceTraders.json#L155-L170) | Other Agents can chart first; the opportunity and public world state can change between observation and call. |
| Ship-to-Ship Cargo | Transfer requires co-location, equal posture, sender inventory, and receiver capacity, and returns only sender Cargo. [Transfer](../../priv/spec/SpaceTraders.json#L2980-L3030) | This is the only direct multi-Ship mutation in the contract and creates an explicit two-Ship rendezvous/capacity dependency. |
| API capacity | Current official limits are independently stated for IP address and Account: 2 requests/second with a 30-request burst over 60 seconds; rate-limit rejection is 429. [Official limits](https://docs.spacetraders.io/api-guide/rate-limits#rate-limits) | Reads, polling and mutations compete for shared request capacity across Ships/Agents using those scopes. |

## Registration and Server Reset Surface

### Contract Facts

- The AccountToken authorizes Agent creation; an AgentToken authorizes game
  endpoints during a **specific reset**. [Security schemes](../../priv/spec/SpaceTraders.json#L61-L73)
- Registration requires AccountToken, symbol and faction, accepts optional
  email for a reserved call sign, uppercases the symbol, and returns the new
  reset Agent, token, faction, Contract and starting Ships. [Registration](../../priv/spec/SpaceTraders.json#L247-L321)
- Registration prose promises 175,000 credits, a command Ship and a small probe,
  while the response itself is the authoritative minted state. [Registration
  prose](../../priv/spec/SpaceTraders.json#L249-L250)
- Public status exposes last reset date, exact next reset time and intended
  frequency. [Status schema](../../priv/spec/SpaceTraders.json#L99-L102); [next
  reset](../../priv/spec/SpaceTraders.json#L175-L188)

### Current First-Party Documentation

The official reset page says reset is normal during alpha; all Agents and all
game data, including Systems, Ships and Cargo, are wiped; previous Agent final
status is retained under the Account; and the Agent must be registered again
through the account dashboard or `/register`. It says the game currently resets
every 7 or 14 calendar days but directs clients to `serverResets` for exact
timing. [Official Server Resets](https://docs.spacetraders.io/server-resets).

This establishes **replacement minting**, not revival of the old AgentToken.
The contract has no reset event stream, callback, token-refresh, Agent delete,
Agent rename, or Agent restore endpoint. Reset discovery is therefore limited
to status fields and failed use of the reset-scoped AgentToken; exact reset
error-code semantics are outside the bundled contract.

### Live Observation, 2026-09-10

An unauthenticated first-party [status response](https://api.spacetraders.io/v2)
captured at `2026-09-10T13:33:29Z` reported version `v2.3.0`,
`resetDate: 2026-09-06`, and
`serverResets.next: 2026-09-13T13:00:00.000Z` with frequency `weekly`. It also
reported 119 Agents, 37,831 Ships, 7,026 Systems, and 203,127 Waypoints. These
values are reset/current-server observations, not contract guarantees.

The live response included an undocumented `health.lastMarketUpdate` field.
Because the bundled status schema does not define `health`, it is not a
contracted observation and cannot be required for complete support.

The relevant mutable values are retained here so the dated observation remains
auditable after the live endpoint changes:

```json
{
  "version": "v2.3.0",
  "resetDate": "2026-09-06",
  "stats": {"agents": 119, "ships": 37831, "systems": 7026, "waypoints": 203127},
  "leaderboards": {
    "mostCredits": {"records": 15, "leader": {"agentSymbol": "MAWHRIN-SKEL", "credits": 1599937761}},
    "mostSubmittedCharts": {"records": 5, "leader": {"agentSymbol": "WHATER", "chartCount": 22075}}
  },
  "serverResets": {"next": "2026-09-13T13:00:00.000Z", "frequency": "weekly"}
}
```

## Leaderboard and Measurement Surface

### Official Categories

| Category | Contracted records | What changes it | Current live shape (2026-09-10) |
| --- | --- | --- | --- |
| `mostCredits` | Ordered array of `agentSymbol` and int64 `credits`, described as top Agents with most credits. [Schema](../../priv/spec/SpaceTraders.json#L136-L154) | Any action returning changed Agent credits: trade, Contract payments, chart rewards, acquisition/refuel/Jump/modification/repair spending, scrap earnings. The API does not expose attribution totals. | 15 records were returned; leader had 1,599,937,761 credits. Array length is not constrained by schema. [Live status](https://api.spacetraders.io/v2); [captured values](#live-observation-2026-09-10) |
| `mostSubmittedCharts` | Ordered array of `agentSymbol` and `chartCount`, described as top Agents with most charts submitted. [Schema](../../priv/spec/SpaceTraders.json#L155-L172) | Successful one-time `create-chart`. [Operation](../../priv/spec/SpaceTraders.json#L1765-L1797) | 5 records were returned; leader had 22,075 charts. Array length is not constrained by schema. [Live status](https://api.spacetraders.io/v2) |

The contract calls these arrays leaderboards but does not explicitly promise
sort direction, rank numbers, tie handling, update latency, inclusion cutoff,
or final archival. The descriptions imply descending "most" order; clients
can observe array order but should not invent tie semantics.

### Other Available Measurements, Not Official Categories

| Measurement | Available source | Limitation |
| --- | --- | --- |
| Current credits and Ship count for public Agents | Paginated `get-agents` and `get-agent`; fields are required on `Agent`. [Agent](../../priv/spec/models/Agent.json#L21-L36); [list](../../priv/spec/SpaceTraders.json#L1013-L1072) | A caller may derive a current Ship-count ordering or independently enumerate credits, but the server does not call Ship count a leaderboard or provide a historical/final rank. |
| Current own Agent economics | `get-my-agent` and Agent-bearing mutation responses. [Own Agent](../../priv/spec/SpaceTraders.json#L981-L1011) | Only current balance/Ship count, not revenue, costs, profit, assets, net worth, or attribution by action/Ship. Credits may be negative. |
| Current Fleet state | Paginated `get-my-ships` with complete Ship records. [Fleet](../../priv/spec/SpaceTraders.json#L1401-L1437) | No public Fleet composition endpoint and no aggregate production/utilization/history. |
| Contract progress and rewards | Own Contract reads expose accepted/fulfilled flags, deadlines, payment terms, and deliveries. [Contract](../../priv/spec/models/Contract.json#L15-L45); [terms](../../priv/spec/models/ContractTerms.json#L1-L22) | Private to the Agent; no public completion leaderboard or contribution attribution. |
| Construction progress | Public Construction read exposes material totals and completion. [Construction](../../priv/spec/models/Construction.json#L1-L22) | No contributor identity, delivered-by-Agent totals, history, or official ranking. |
| Global population/world totals | Status stats expose Accounts (optional), Agents, Ships, Systems and Waypoints. [Stats](../../priv/spec/SpaceTraders.json#L106-L130) | Global totals, not per-Agent performance. |
| Market/Shipyard recent transactions | Visible when a Ship is present according to operation/model descriptions. [Market](../../priv/spec/models/Market.json#L30-L45); [Shipyard operation](../../priv/spec/SpaceTraders.json#L637-L688) | Partial recent local history, not a complete Agent ledger or leaderboard source. |

No official endpoint exposes leaderboard history or snapshots from the previous
reset. The reset documentation's Account-retained "final status" is not given
an API schema or endpoint, so its fields and programmatic accessibility are
unknown. [Official Server Resets](https://docs.spacetraders.io/server-resets).

## API Limits and Failure Surface

Current official documentation states both IP-address and Account limits of 2
requests/second, a burst of 30 requests over 60 seconds, and HTTP 429 on limit
exhaustion. A rate-limiter 429 includes `Retry-After`,
`X-RateLimit-Type`, `X-RateLimit-Limit`, `X-RateLimit-Remaining`,
`X-RateLimit-Reset`, `X-RateLimit-Limit-Burst`, and
`X-RateLimit-Limit-Per-Second` as applicable. Cloud infrastructure can also
emit 429 without those headers; official guidance says identify the source by
headers and use exponential backoff otherwise. DDoS protection can emit 502,
for which the page says wait a few minutes. [Official limits](https://docs.spacetraders.io/api-guide/rate-limits#rate-limits);
[headers](https://docs.spacetraders.io/api-guide/rate-limits#response-headers);
[example](https://docs.spacetraders.io/api-guide/rate-limits#example-response).

The bundled OpenAPI operations document success responses only; they do not
attach error response schemas or endpoint-specific codes. The official error
catalogue is grouped into general, Account, Ship, Contract, Market, Faction,
and Construction codes and describes itself as a non-exhaustive work in
progress. It is useful failure vocabulary, not a contract mapping every code to
every operation. [Official response errors](https://docs.spacetraders.io/api-guide/response-errors#general-error-codes).

Across the mutation inventory, the API exposes failure status/code/message/data
and the following **observable conditions**. The contract does not establish
that an unobserved failure is permanent or that a repeated mutation is safe:

| Failure class | Material examples across the inventory | Available follow-up evidence |
| --- | --- | --- |
| Temporal/readiness | In transit, active cooldown, Contract acceptance/completion deadline, expired Survey, rate limit. | Nav/Arrival, Cooldown, Contract, Survey expiration, or rate-limit reset/Retry-After. |
| Location/posture | Wrong Waypoint/System, docked vs orbit, absent Marketplace/Shipyard/Jump Gate/faction/Construction. | Fresh Ship Nav plus Waypoint and facility read. |
| Capability | Missing mount/module, insufficient slots/power/crew, incompatible extraction/refining/scanning/travel capability. | Fresh complete Ship and relevant component requirements; mutation call remains final eligibility authority. |
| Resource/contention | Credits, fuel, Cargo quantity/capacity, Market price/supply/trade volume, Shipyard offer/quote, outstanding Contract/Construction units, Survey exhaustion. | Fresh owner/facility/project state; shared values may change again before mutation. |
| Identity/authority | Invalid AccountToken/AgentToken, reset mismatch, duplicate symbol, unknown owned entity. | Public status reset identity, then successful authenticated Agent read or replacement registration evidence. |
| Ambiguous transport/server | Timeout, 5xx, infrastructure 429/502, malformed/unexpected response. | The mutation's returned-state equivalents can distinguish some outcomes. Only orbit/dock are contractually idempotent. |
| Irreversible/final | Jettisoned Cargo, consumed/delivered/supplied goods, spent fuel/credits, chart submission, accepted/fulfilled Contract, component integrity loss, scrapped Ship. | Reconciliation can prove outcome but cannot undo it through an inverse API operation. |

## Contract Defects and Material Unknowns

- Registration defines `ships` but its required list says `ship`. Consumers
  must follow returned data, and the contract should not be read as promising a
  singular field. [Registration response](../../priv/spec/SpaceTraders.json#L289-L317)
- Refuel prose says Ships always fill to maximum while its request schema
  permits optional partial `units` and `fromCargo`; partial behavior and
  transaction semantics are settled only by the live response. [Refuel](../../priv/spec/SpaceTraders.json#L2824-L2873)
- `patch-ship-nav` currently supports flight mode but marks no body field
  required. Empty-patch behavior is unknown. [Patch Nav](../../priv/spec/SpaceTraders.json#L2401-L2450)
- Module install/remove omit docking and Shipyard prerequisites while
  `Shipyard.modificationsFee` explicitly prices module changes. Exact legal
  modification context and reduced-capacity removal behavior remain unknown.
  All three module operations also omit operation-level security and therefore
  inherit the malformed global requirement for both token schemes; live
  authorization behavior is unknown. [Module operations](../../priv/spec/SpaceTraders.json#L3566-L3784);
  [global security](../../priv/spec/SpaceTraders.json#L16-L20); [fee](../../priv/spec/models/Shipyard.json#L37-L40)
- Scan posture/range, Jump's precise origin facility/market requirements,
  action eligibility during cooldown, extraction modifier thresholds, market
  update timing, and endpoint-specific error mappings are not fully specified
  by the contract. They remain API-enforced mechanics; current docs clarify
  portions but do not constitute complete endpoint contracts.
- Repair and scrap are preview features; official documentation says their
  tuning is provisional. [Contract flags](../../priv/spec/SpaceTraders.json#L3307-L3358);
  [official maintenance overview](https://docs.spacetraders.io/game-concepts/maintenance#overview)
- No API exposes Account-retained previous-reset final status, canonical
  leaderboard history, reset event notifications, cancellation, reservations,
  bulk actions, atomic multi-action transactions, or mutation idempotency keys.

## Ticket Completeness Check

| #300 requirement | Covered in this report |
| --- | --- |
| Complete current API surface | All 59 operation IDs: 33 mutations in four inventory sections and all 26 GETs in the observation inventory. |
| Every mutation's observations and prerequisites | Each mutation row identifies required current state and preconditions, with contract anchors. |
| Async waits | Transit/Arrival, cooldown, Survey lifetime, Contract deadlines, reset schedule, and rate-limit waits. |
| Shared resources and cross-Ship coordination | Credits/Fleet, Ship exclusivity, Contracts, Markets, Construction, Surveys, charts, Cargo transfer, and API capacity. |
| Authoritative success evidence | Every mutation row names its success response fields; ambiguous outcomes are tied to read reconciliation. |
| Recoverable failures | Per-action failure boundaries plus cross-cutting temporal, location, capability, resource, identity, and transport classes. |
| Irreversible consequences | Explicitly marked for registration, delivery/supply, acceptance/fulfillment, refine, chart, gather wear, jettison, movement/trade spending, repair integrity, and scrap. |
| Registration and Server Reset | Separate contract, current-doc, and dated live-observation sections. |
| Leaderboards and measurements | Both canonical categories, current live shape, all other available measurements, and explicit absences. |
| API limits | IP/Account steady and burst limits, 429 headers, infrastructure ambiguity, and 502 guidance. |
| Research-only boundary | No application behavior, capability decomposition, Policy, Intent, persistence, UI, architecture, or coordination design is proposed. |

## Primary Sources Consulted

- Checked-in OpenAPI v2.3.0 contract:
  [`priv/spec/SpaceTraders.json`](../../priv/spec/SpaceTraders.json) and its
  referenced [`priv/spec/models/`](../../priv/spec/models/) schemas.
- Official SpaceTraders OpenAPI source at commit
  [`45fbb041`](https://github.com/SpaceTradersAPI/api-docs/commit/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab).
- Official documentation: [Server Resets](https://docs.spacetraders.io/server-resets),
  [Rate Limits](https://docs.spacetraders.io/api-guide/rate-limits),
  [Response Errors](https://docs.spacetraders.io/api-guide/response-errors),
  [Markets](https://docs.spacetraders.io/game-concepts/markets),
  [Extracting Resources](https://docs.spacetraders.io/game-concepts/extracting-resources),
  [Exploration](https://docs.spacetraders.io/game-concepts/exploration), and
  [Maintenance](https://docs.spacetraders.io/game-concepts/maintenance).
- First-party live unauthenticated
  [`GET https://api.spacetraders.io/v2`](https://api.spacetraders.io/v2),
  observed 2026-09-10.
