# Ship Outfitting and Module Acquisition Mechanics

Research for the Phase 3.5 Wayfinder ticket "Research Ship outfitting and
module acquisition mechanics", 2026-08-23.

## Executive Answer

A module is both a Ship component and a Trade Good. The bundled API contract
permits the assigned Ship to buy one as Cargo at a Market, provided the Ship is
docked there, the Market currently sells that symbol, the transaction does not
exceed `tradeVolume`, Cargo has room, and the Agent can pay. Installation then
requires that module symbol in the same Ship's Cargo and returns the resulting
Agent, a module array, Cargo, and modification transaction. Removal returns the
same response fields and places the removed module in Cargo. [Purchase Cargo,
`purchase-cargo`](../../priv/spec/SpaceTraders.json#L2904-L2978);
[Install Ship Module, `install-ship-module`](../../priv/spec/SpaceTraders.json#L3606-L3693);
[Remove Ship Module, `remove-ship-module`](../../priv/spec/SpaceTraders.json#L3695-L3779).

The Ship is valid only when its installed components fit the frame's module
slots and its combined component requirements fit available reactor power and
crew. The contract exposes each module's `requirements.power`,
`requirements.crew`, and `requirements.slots`, the frame's `moduleSlots`, the
reactor's `powerOutput`, and crew state; current official Outfitting
documentation explicitly says validity is based on the combined requirements
and values. [Ship requirements](../../priv/spec/models/ShipRequirements.json#L1-L18);
[frame](../../priv/spec/models/ShipFrame.json#L3-L45);
[reactor](../../priv/spec/models/ShipReactor.json#L3-L34);
[crew](../../priv/spec/models/ShipCrew.json#L3-L35);
[official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting).

The contract does **not** settle where module installation/removal is legal.
Unlike mount modification, the module endpoints say only that the item must be
in Cargo or will be placed there; they do not state docking or Shipyard
requirements. Yet `Shipyard.modificationsFee` explicitly covers installing and
removing modules at a Shipyard, charging per occupied slot. This strongly
indicates Shipyard modification semantics but does not contractually prove that
all module modifications require a docked Ship at a Shipyard. The generic
first-party error catalogue includes ship-not-docked, insufficient-power,
insufficient-slots, and insufficient-crew errors, but does not map errors to
these endpoints and calls its own list non-exhaustive. Treat exact location and
posture preconditions as unresolved and API-enforced, not as invented local
rules. [Module operations](../../priv/spec/SpaceTraders.json#L3606-L3779);
[Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L42);
[mount contrast](../../priv/spec/SpaceTraders.json#L3152-L3153);
[official response errors](https://docs.spacetraders.io/api-guide/response-errors).

For a Warp Drive specifically, all three symbols are valid `ShipModule` and
`TradeSymbol` values, and a successful warp requires an installed Warp Drive.
Those facts make Market purchase and Cargo installation syntactically possible,
but neither the bundled contract nor current first-party documentation promises
that any Market actually lists a Warp Drive in a given reset. A Shipyard's
public model lists ships, not loose modules. Therefore the authoritative
acquisition question is answered only by an observed Market listing; absent
one, availability is unknown rather than impossible. [Module symbols](../../priv/spec/models/ShipModule.json#L20-L27);
[Trade Good symbols](../../priv/spec/models/TradeSymbol.json#L101-L120);
[Warp Ship, `warp-ship`](../../priv/spec/SpaceTraders.json#L2514-L2581);
[Market](../../priv/spec/models/Market.json#L9-L45);
[Shipyard](../../priv/spec/models/Shipyard.json#L10-L42).

## Source Classification

| Classification | Meaning in this note |
| --- | --- |
| Contract fact | Stated by the bundled API v2.3.0 OpenAPI contract, the repository's contract ground truth. [Spec identity](../../priv/spec/SpaceTraders.json#L1-L6) |
| First-party documentation | Current SpaceTraders-owned explanatory documentation used only where the bundled contract is silent or contradictory. [Official OpenAPI guide](https://docs.spacetraders.io/api-guide/open-api-spec) |
| First-party observation | A dated response from the live SpaceTraders API; useful evidence about this reset, never a universal rule. [API root](https://api.spacetraders.io/v2/) |
| Unknown | Neither the bundled contract nor current first-party material settles the mechanic. It must not be guessed. |

## Mechanics by Lifecycle

### 1. Discover a Source

**Market availability is the relevant loose-module source in the contract.**
`GET /systems/{systemSymbol}/waypoints/{waypointSymbol}/market`
(`get-market`) requires a `MARKETPLACE` Waypoint. Its `exports`, `imports`, and
`exchange` disclose composition without requiring an owned Ship to be present;
`tradeGoods`, which supplies live type, `tradeVolume`, supply, purchase price,
and sell price, is visible only while a Ship is present. [Get Market](../../priv/spec/SpaceTraders.json#L585-L635);
[Market](../../priv/spec/models/Market.json#L9-L45);
[Market Trade Good](../../priv/spec/models/MarketTradeGood.json#L3-L35).

A module symbol may appear as a Market good because `TradeSymbol` contains the
module symbols, including all three Warp Drives. This is type-level permission,
not a guarantee that world generation supplies any particular module at any
Market. [Trade symbols](../../priv/spec/models/TradeSymbol.json#L101-L120).

**Shipyard availability is different.** `GET .../shipyard` (`get-shipyard`)
requires a `SHIPYARD` Waypoint and discloses ship types; full Ship offers and
recent transactions require Ship presence. `Shipyard` has no loose-module or
mount inventory field. Its only module-specific fact is `modificationsFee`.
Ship purchases can include preset modules, but that is availability on a newly
purchased Ship, not loose-module availability for the assigned Ship. [Get
Shipyard](../../priv/spec/SpaceTraders.json#L637-L688); [Shipyard](../../priv/spec/models/Shipyard.json#L10-L42);
[Purchase Ship description](../../priv/spec/SpaceTraders.json#L1462-L1463).
The official Outfitting page nevertheless refers to being docked at a Shipyard
"that sells mounts or modules" while describing a possible future direct-use
simplification. No current contract field or operation exposes that loose stock
or a Shipyard component purchase, so whether such inventory exists but is
unexposed is unknown. [Official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting);
[Shipyard schema](../../priv/spec/models/Shipyard.json#L4-L42); [Fleet operation
inventory](../../priv/spec/SpaceTraders.json#L1404-L3780).

### 2. Acquire and Carry

`POST /my/ships/{shipSymbol}/purchase` (`purchase-cargo`) requires the Ship to
be docked at a `MARKETPLACE`, requires that Market to sell the requested symbol,
and limits one transaction to the observed good's `tradeVolume`. The request is
`{symbol: TradeSymbol, units: integer}`. A 201 response returns the updated
Agent, Cargo, and `MarketTransaction`, making both payment and Cargo receipt
authoritative. [Purchase Cargo](../../priv/spec/SpaceTraders.json#L2904-L2957).

Cargo is bounded by `capacity`; `units` is the total currently stored, and each
inventory entry records symbol and positive unit count. The module therefore
occupies Cargo while carried, but the contract does not separately define item
volume or mass: every unit contributes to the same unit-capacity model. [Ship
Cargo](../../priv/spec/models/ShipCargo.json#L1-L24); [Cargo item](../../priv/spec/models/ShipCargoItem.json#L1-L22).

The installed module must be in **that Ship's** Cargo. The official Outfitting
page also says the Ship doing the switching must have the mount or module in its
own Cargo and characterizes direct use of Shipyard stock as a possible future
simplification, not a current mechanic. [Install description](../../priv/spec/SpaceTraders.json#L3606-L3611);
[official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting).

Cargo transfer is technically another acquisition route, but it requires two
Ships at the same Waypoint, in the same docked/orbiting state, with receiving
capacity. It is outside the stated single-Ship mechanic and cannot be assumed
as an acquisition path for this Job. [Transfer Cargo, `transfer-cargo`](../../priv/spec/SpaceTraders.json#L2980-L3039).

### 3. Validate Compatibility

The frame sets total `moduleSlots`; each module may require
`requirements.slots`. Reactor `powerOutput`, crew state, and every component's
`requirements.power` and `requirements.crew` are exposed. The current official
Outfitting page says a Ship is valid when combined power and crew requirements
do not exceed combined values provided by its components. It also says frame,
reactor, and engine cannot be swapped after purchase, whereas modules and
mounts can. [Frame](../../priv/spec/models/ShipFrame.json#L3-L57); [module](../../priv/spec/models/ShipModule.json#L31-L53);
[requirements](../../priv/spec/models/ShipRequirements.json#L1-L18);
[official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting).

The contract does not provide a separate compatibility/quote endpoint. The
known preflight arithmetic is therefore aggregate occupied module slots versus
`frame.moduleSlots` and aggregate power/crew requirements versus the Ship's
available values; the install call remains authoritative because requirement
fields are optional within `ShipRequirements`, the exact aggregate formula is
not in the contract, and the API can enforce additional rules. [Requirements
schema](../../priv/spec/models/ShipRequirements.json#L3-L17); [Install Ship
Module](../../priv/spec/SpaceTraders.json#L3606-L3693).

Module-provided capacity can alter Ship state. `ShipModule.capacity` is a
generic optional bonus for Cargo holds or crew quarters, but the contract does
not state how to derive post-install/post-remove Cargo or crew capacity from
that field. The returned authoritative Cargo and subsequent Ship state must be
used rather than locally synthesizing the result. [Module capacity](../../priv/spec/models/ShipModule.json#L31-L35);
[Ship](../../priv/spec/models/Ship.json#L15-L49).

### 4. Reach the Modification Context

The contract clearly says orbiting Ships cannot access a Market or Shipyard,
and Market purchase explicitly requires docking. Docking returns authoritative
navigation state. [Orbit posture](../../priv/spec/SpaceTraders.json#L1610-L1613);
[Purchase Cargo](../../priv/spec/SpaceTraders.json#L2904-L2907); [Dock Ship,
`dock-ship`](../../priv/spec/SpaceTraders.json#L1868-L1914).

For module installation/removal, however, the bundled operation descriptions
omit docking, Waypoint, and Shipyard requirements. In contrast, mount install
and removal explicitly require a docked Ship at a `SHIPYARD`. The Shipyard fee
schema says module modification is performed there and charged per occupied
slot, but does not say it is the exclusive location. [Module operations](../../priv/spec/SpaceTraders.json#L3606-L3779);
[Install Mount](../../priv/spec/SpaceTraders.json#L3152-L3153); [Remove Mount](../../priv/spec/SpaceTraders.json#L3230-L3231);
[Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L40).

Consequently, "docked at a Shipyard" is strongly supported but not settled as
a module endpoint precondition. Fresh Ship/Waypoint/Shipyard state may inform
planning or explain an API rejection, but it must not become a local blocking
eligibility rule without authoritative evidence. Only a module operation
response can establish actual eligibility under the current API. This follows
the repository rule that game truth is authoritative and local checks must not
silently narrow it. [ADR 0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md).

### 5. Install

`POST /my/ships/{shipSymbol}/modules/install` takes one module `symbol` and
requires that module in Cargo. Its 201 response requires:

- updated `agent`, including credits;
- a `modules` array;
- updated `cargo`;
- a transaction with Waypoint, Ship, trade symbol, total price, and timestamp.

[Install request and response](../../priv/spec/SpaceTraders.json#L3606-L3691);
[Ship modification transaction](../../priv/spec/models/ShipModificationTransaction.json#L1-L29).

`Shipyard.modificationsFee` defines the charge for modification at that
Shipyard as a fee per occupied slot. The transaction's `totalPrice` is the
authoritative actual charge for a successful operation. Because the module
endpoints do not settle where modification occurs, the contract also does not
prove that every module operation incurs that Shipyard fee. Nor does it state
whether zero-slot or missing-slot modules are free, how a fee is rounded, or
whether any additional multiplier applies; do not calculate a final debit
beyond a fresh quote-like Shipyard observation.
[Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L40); [transaction](../../priv/spec/models/ShipModificationTransaction.json#L16-L27).

### 6. Remove

`POST /my/ships/{shipSymbol}/modules/remove` takes one installed module symbol,
returns a module array, and places the module in Cargo. The same required
Agent/Cargo/transaction fields make the resulting debit and Cargo state
authoritative. [Remove request and response](../../priv/spec/SpaceTraders.json#L3695-L3779).

Removal has three material consequences:

- At a Shipyard it is subject to the per-slot modification fee; whether every
  successful removal necessarily incurs that fee is unresolved. [Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L40)
- It consumes Cargo capacity because the module is placed in Cargo. [Remove description](../../priv/spec/SpaceTraders.json#L3697-L3700)
- It can remove capability or capacity supplied by that module; the returned
  modules and Cargo authoritatively establish those fields, while a fresh Get
  Ship is required to reconcile full resulting readiness. [Module](../../priv/spec/models/ShipModule.json#L2-L50); [Get Ship](../../priv/spec/SpaceTraders.json#L1524-L1565)

The schema statement "Module installations are permanent" conflicts directly
with the remove endpoint and the official Outfitting page's statement that
modules can be removed/switched. The actionable contract surface includes a
successful removal response, so removability is real; "permanent" must not be
used to declare removal impossible. Its intended meaning remains unknown.
[Module description](../../priv/spec/models/ShipModule.json#L2-L4); [Remove Ship
Module](../../priv/spec/SpaceTraders.json#L3695-L3779); [official Outfitting
documentation](https://docs.spacetraders.io/game-concepts/outfitting).

The contract does not specify what happens if removing a Cargo-hold or
crew-capacity module would leave current usage above the reduced capacity. The
official error list's cargo-limit/full and crew errors make rejection plausible,
but the exact endpoint behavior and mutation ordering are unknown. [Official
ship error codes](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes).

### 7. Revalidate

`GET /my/ships/{shipSymbol}` (`get-my-ship`) returns the authoritative complete
Ship, including frame, reactor, crew, installed modules, Cargo, navigation,
fuel, mounts, engine, and cooldown. `GET .../modules` (`get-ship-modules`)
returns the installed module array only. [Get Ship](../../priv/spec/SpaceTraders.json#L1524-L1565);
[Ship](../../priv/spec/models/Ship.json#L4-L64); [Get Ship Modules](../../priv/spec/SpaceTraders.json#L3566-L3604).

The modification response is immediate authoritative success evidence. A
fresh Get Ship is the stronger durable reconciliation point after a timeout,
restart, ambiguous transport result, or possible external change, consistent
with the repository rule that local Ship state is a cache and server state is
truth. [Install response](../../priv/spec/SpaceTraders.json#L3639-L3691);
[Remove response](../../priv/spec/SpaceTraders.json#L3728-L3779); [ADR 0005](../adr/0005-async-time-per-entity-timers.md).

## Warp Drive Acquisition Analysis

1. **Capability identity is settled.** `MODULE_WARP_DRIVE_I`, `_II`, and `_III`
   are valid module and Trade Good symbols. The warp operation requires an
   installed "Warp Drive" module; the contract does not say which tiers are
   accepted or expose a separate warp-capability flag. [Ship Module](../../priv/spec/models/ShipModule.json#L20-L27);
   [Trade Symbol](../../priv/spec/models/TradeSymbol.json#L111-L120); [Warp Ship](../../priv/spec/SpaceTraders.json#L2514-L2517).
2. **Market purchase is contractually expressible.** `purchase-cargo` accepts a
   `TradeSymbol`, so it can request a Warp Drive if the on-site Market actually
   sells one. Success returns the Warp Drive in authoritative Cargo. [Purchase
   request](../../priv/spec/SpaceTraders.json#L2904-L2957).
3. **Availability is not promised.** Market composition is dynamic world data,
   and no endpoint searches Markets by Trade Good. Neither `Market` nor current
   official docs assert that Warp Drives are generated for sale. A missing
   listing in known Markets proves only "not available there in that
   observation," not global impossibility. [Market](../../priv/spec/models/Market.json#L9-L45);
   [official Markets documentation](https://docs.spacetraders.io/game-concepts/markets).
4. **Shipyards do not advertise loose Warp Drives.** Their contract inventory
   is Ships. A Ship offer can have preset modules, but extracting one would
   require another Ship and removal/transfer mechanics, so it is not a
   single-Ship acquisition route. [Shipyard](../../priv/spec/models/Shipyard.json#L10-L42);
   [Purchase Ship description](../../priv/spec/SpaceTraders.json#L1462-L1463).
5. **No crafting, salvage-to-module, or direct Shipyard module-purchase endpoint
   exists in the bundled contract.** Therefore a Warp Drive already installed
   on the assigned Ship, already in its Cargo, or observed as purchasable Cargo
   at a Market are the only contract-supported single-Ship states established
   by these sources. This is an endpoint-inventory conclusion, not a claim that
   future APIs or undocumented world events cannot add another source. [Fleet
   operation inventory](../../priv/spec/SpaceTraders.json#L1404-L3780).

## Authoritative Completion Evidence

For the narrow outcome "the assigned Ship has requested module capability,"
the authoritative evidence is a successful module-install response whose
`data.modules` contains the requested symbol, followed where reconciliation is
needed by `get-my-ship` showing that symbol in `Ship.modules`. Cargo absence and
the modification transaction corroborate consumption and payment but do not by
themselves prove installed capability. [Install response](../../priv/spec/SpaceTraders.json#L3639-L3691);
[Ship modules](../../priv/spec/models/Ship.json#L30-L35); [Get Ship](../../priv/spec/SpaceTraders.json#L1524-L1565).

For a semantic capability such as warp, installed-symbol evidence is the only
readiness evidence exposed before use. An actual successful `warp-ship`
response proves the capability worked for that action and returns new Nav/Fuel,
but performing a warp is not required by the API contract to prove that a Warp
Drive is installed. [Warp response](../../priv/spec/SpaceTraders.json#L2514-L2560).

An HTTP timeout or lost 201 response is not evidence of failure. Re-read the
Ship before retrying because installation is state-changing and the contract
does not declare the endpoint idempotent. [Install operation](../../priv/spec/SpaceTraders.json#L3606-L3693);
[ADR 0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md).

## Failure and Uncertainty Table

The bundled operation objects document only success responses for Market,
Shipyard, purchase, install, remove, and module reads; they do **not** attach
documented error codes. The current official error catalogue says it is a work
in progress and non-exhaustive. Codes below are therefore relevant first-party
failure vocabulary, not guaranteed endpoint mappings. [Purchase responses](../../priv/spec/SpaceTraders.json#L2928-L2959);
[module responses](../../priv/spec/SpaceTraders.json#L3583-L3603);
[official response-error caveat](https://docs.spacetraders.io/api-guide/response-errors#general-error-codes).

| Condition | Evidence and consequence | Status |
| --- | --- | --- |
| No Market or Market does not sell symbol | Purchase requires a docked Ship at a Market that sells the good. Official codes include `4603 marketNotFound` and `4601 marketTradeNoPurchase`. [Purchase Cargo](../../priv/spec/SpaceTraders.json#L2904-L2907); [Market errors](https://docs.spacetraders.io/api-guide/response-errors#market-error-codes) | Contract fact plus first-party error vocabulary |
| Stale price/supply or amount above `tradeVolume` | On-site `tradeGoods` is the live listing; one trade is bounded by `tradeVolume`. Official code `4604` names the unit limit. [Market](../../priv/spec/models/Market.json#L37-L43); [Market Trade Good](../../priv/spec/models/MarketTradeGood.json#L12-L26); [Market errors](https://docs.spacetraders.io/api-guide/response-errors#market-error-codes) | Contract fact plus first-party error vocabulary |
| Insufficient purchase credits | Purchase returns updated Agent and transaction only on success; official code `4600` names insufficient Market credits. [Purchase response](../../priv/spec/SpaceTraders.json#L2928-L2957); [Market errors](https://docs.spacetraders.io/api-guide/response-errors#market-error-codes) | First-party error vocabulary; exact debit is live data |
| Cargo lacks room for purchase or removal | Cargo has finite capacity. Official codes include `4217 shipCargoExceedsLimit` and `4228 shipCargoFull`; endpoint mapping and removal behavior are undocumented. [Cargo](../../priv/spec/models/ShipCargo.json#L4-L22); [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) | Constraint is contract fact; exact removal failure is unknown |
| Requested install module absent from Cargo | Install explicitly requires it in Cargo. Official `4218 shipCargoMissing` is relevant but not mapped by the spec. [Install](../../priv/spec/SpaceTraders.json#L3606-L3611); [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) | Contract fact plus first-party error vocabulary |
| Insufficient slots, power, or crew | Requirements and capacities are exposed; official codes are `4250 shipMissingSlots`, `4249 shipMissingPower`, and `4252 shipMissingCrew`. [Requirements](../../priv/spec/models/ShipRequirements.json#L3-L17); [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) | Mechanic supported by first-party docs; exact arithmetic/API mapping incomplete |
| Ship in transit or wrong posture | Official codes include `4214 shipInTransit` and `4244 shipNotDocked`. Module endpoints omit posture requirements. [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes); [module operations](../../priv/spec/SpaceTraders.json#L3606-L3779) | Relevant failure vocabulary; module applicability unknown |
| No Shipyard at location | `4246 shipMountNoShipyard` is explicitly mount-named; no module equivalent is documented. Shipyard fee includes modules, creating an unresolved omission. [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes); [Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L40) | Unknown for module endpoints |
| Insufficient modification credits | Transaction and Agent report actual successful debit. The official only names `4248 shipMountInsufficientCredits`, not a module-specific code. [Install response](../../priv/spec/SpaceTraders.json#L3648-L3685); [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) | Shipyard fee is a contract fact; applicability and module-specific error mapping are unknown |
| Remove symbol not installed | Remove says the operation removes a module but specifies no error response or duplicate-symbol selection behavior. [Remove](../../priv/spec/SpaceTraders.json#L3695-L3779) | Unknown error and duplicate semantics |
| Removal would invalidate capacity/crew/power | Removed module enters Cargo and may have provided capacity. No mutation-order or rollback rule is documented. [Remove](../../priv/spec/SpaceTraders.json#L3695-L3779); [module capacity](../../priv/spec/models/ShipModule.json#L31-L35) | Unknown |
| Warp Drive unavailable in observed Markets | Symbols are legal but generation/availability is not promised. Absence from partial intelligence is not impossibility. [Trade symbols](../../priv/spec/models/TradeSymbol.json#L111-L120); [Market](../../priv/spec/models/Market.json#L9-L45) | Unknown until authoritative listing observation |
| Warp attempted without installed drive | Official code `4241 shipMissingWarpDrive`; Warp operation also states the requirement. [Warp Ship](../../priv/spec/SpaceTraders.json#L2514-L2517); [Ship errors](https://docs.spacetraders.io/api-guide/response-errors#ship-error-codes) | Contract fact and first-party error vocabulary |
| API timeout after mutation | Neither module endpoint is declared idempotent; outcome must be reconciled from Get Ship rather than inferred or blindly replayed. [Install](../../priv/spec/SpaceTraders.json#L3606-L3693); [Remove](../../priv/spec/SpaceTraders.json#L3695-L3779); [Get Ship](../../priv/spec/SpaceTraders.json#L1524-L1565) | Contract omission; safe evidence rule |

## Strict Mechanics Guardrails

These are boundaries implied by the mechanics, not a Job or Operator workflow:

1. Treat Market composition and Shipyard fees as observed, reset-scoped world
   state; do not hard-code a source, price, trade volume, or modification fee.
   [Market](../../priv/spec/models/Market.json#L9-L45); [Shipyard](../../priv/spec/models/Shipyard.json#L37-L42)
2. Never claim a module is obtainable merely because its symbol is in
   `TradeSymbol`; require an authoritative Market listing or existing assigned-
   Ship state. [Trade Symbol](../../priv/spec/models/TradeSymbol.json#L101-L120);
   [Purchase Cargo](../../priv/spec/SpaceTraders.json#L2904-L2907)
3. Never claim compatibility from slot count alone; account for module slots,
   aggregate power, crew, and API validation. [Official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting);
   [Ship Requirements](../../priv/spec/models/ShipRequirements.json#L1-L18)
4. Never remove a module as an implicit prerequisite. Removal may incur a
   Shipyard fee, consumes Cargo room, can remove capability/capacity, and the
   repository's Ship Outfitting Job definition requires explicit Operator
   permission.
   [Remove response](../../priv/spec/SpaceTraders.json#L3728-L3779); [domain definition](../../CONTEXT.md#L141-L143)
5. Declare success only from authoritative installed-module state; retain
   uncertainty after ambiguous calls and reconcile with Get Ship. [Install
   response](../../priv/spec/SpaceTraders.json#L3639-L3691); [Get Ship](../../priv/spec/SpaceTraders.json#L1524-L1565)

## Material Unresolved Questions

- Must module install/remove be docked at a Shipyard, merely docked, or can it
  occur elsewhere? The module endpoint descriptions omit the rule while the
  Shipyard fee includes module work. [Module operations](../../priv/spec/SpaceTraders.json#L3606-L3779);
  [Shipyard fee](../../priv/spec/models/Shipyard.json#L37-L40)
- What exact aggregate formula and treatment of absent requirement fields does
  the API use for power and crew validation? First-party docs establish the
  aggregate rule but not its full arithmetic. [Official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting);
  [Ship Requirements](../../priv/spec/models/ShipRequirements.json#L3-L17)
- What happens atomically when removing a capacity-providing module would make
  Cargo units or crew exceed the resulting capacity? No contract response or
  ordering rule settles it. [Module capacity](../../priv/spec/models/ShipModule.json#L31-L35);
  [Remove response](../../priv/spec/SpaceTraders.json#L3728-L3779)
- Are loose Warp Drives generated for sale anywhere in the current reset, and
  if so under what world/faction conditions? The contract permits the symbol
  but promises no source. [Trade Symbol](../../priv/spec/models/TradeSymbol.json#L111-L120);
  [Market](../../priv/spec/models/Market.json#L9-L45)
- Is the `ShipModule` statement that installations are "permanent" stale text,
  or does it denote an undocumented consequence despite the remove endpoint?
  Current first-party sources do not define the term. [Ship Module](../../priv/spec/models/ShipModule.json#L2-L4);
  [official Outfitting documentation](https://docs.spacetraders.io/game-concepts/outfitting)
