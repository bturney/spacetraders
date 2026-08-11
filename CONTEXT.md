# SpaceTraders

A dashboard + bot for playing SpaceTraders, a programmable API game where every action (register, navigate, mine, trade, buy ships) is an HTTP endpoint. This context covers the domain language shared by the Phoenix app, the dashboard, and the API integration.

## Language

### The player

**Agent**:
The in-game player identity created via registration (e.g., ORBITALIST). Registered under an Account via its AccountToken; carries its own AgentToken. Owns its own credits, fleet, contracts, and headquarters.
_Avoid_: player, user, account

**Operator**:
The human who drives the dashboard. Links their own AccountToken once and may mint (own) one or more Agents. Distinct from the in-game Agent.
_Avoid_: player, captain, user

**Mint**:
Creating a new Agent in-app by calling the registration endpoint with an AccountToken and a chosen symbol + faction.
_Avoid_: sign up, create account (for the in-app action)

**Account**:
The external my.spacetraders.io account holding the AccountToken, which mints new Agents. The app stores it encrypted per-Operator for in-app minting; it is never used for game actions.
_Avoid_: agent account, signup

### Space

**System**:
A named region of space containing waypoints (e.g., X1-UX81).

**Waypoint**:
A specific location in a system (e.g., X1-UX81-A1), the atomic unit of movement. May carry traits such as MARKETPLACE, SHIPYARD, or ENGINEERED_ASTEROID.
_Avoid_: planet, station, location

**Parent Waypoint**:
A Waypoint at a coordinate that one or more Orbital Waypoints orbit. The API exposes its children through `orbitals`.

**Orbital Waypoint**:
A Waypoint located at the exact coordinates of its Parent Waypoint, such as a moon or orbital station. The API identifies its parent through `orbits`.

**System Map**:
A visual, interactive representation of every Waypoint in one System, positioned by its game-supplied coordinates and showing the Fleet's current state.
_Avoid_: galaxy map, sector map

**Waypoint Intelligence**:
Operational and contextual metadata returned for a Waypoint beyond its location and immediate navigability: construction status, modifiers, controlling faction, and chart provenance. Construction status and modifiers are operational state; faction and chart provenance are secondary context. Display it when present without a per-selection API request.

**Waypoint Modifier**:
An API-supplied condition affecting a Waypoint (e.g., RADIATION_LEAK or CIVIL_UNREST). It signals caution but has no API-supplied severity ranking; do not infer one.

**Chart Provenance**:
The Agent and time recorded by the game when a Waypoint was charted. It is secondary context, not an operational condition. Its absence is unknown optional data, not a claim that a Waypoint is uncharted.

**Waypoint Grid**:
A structured, actionable view of Waypoints in one System. It is linked to the System Map: selecting a Waypoint in either view selects and highlights it in both.
_Avoid_: waypoint browser, waypoint list

**Galaxy Map**:
A future representation of multiple Systems. It requires a deliberate System discovery model and is distinct from the System Map.
_Avoid_: system map

**Headquarters**:
The Agent's home waypoint, where the Agent starts.

**Waypoint Intelligence**:
The operational state of a Waypoint that the inspector surfaces before any secondary context: construction status and Waypoint Modifiers.
_Avoid_: waypoint stats, waypoint info

**Waypoint Modifier**:
An API-supplied caution flag on a Waypoint (e.g., STRIPPED, UNSTABLE), carrying a symbol, name, and description. Shown with caution styling; the game does not rank modifiers, so the app invents no severity order.
_Avoid_: debuff, penalty, severity

**Chart Provenance**:
The chart facts the API returns for a Waypoint: the submitter and the charted absolute time. Shown only when returned; partial provenance never uses placeholders.
_Avoid_: chart history, discovered-by

### Fleet

**Fleet**:
The collection of ships owned by exactly one Agent. Ships never span Agents.

**Ship**:
A vessel the Agent owns (e.g., ORBITALIST-1, class COMMAND). Travels between waypoints, carries cargo, consumes fuel, and is subject to cooldowns.
_Avoid_: vessel

**Autopilot**:
An Operator-started, per-Ship intent to execute one configured local extract/sell loop. Its persisted configuration and execution status are Fleet state; it never resumes an action without reconciling authoritative game state.
_Avoid_: bot, automatic mode

**Ship Readiness**:
The capability and condition information that determines what a Ship can do: flight mode, crew, frame, reactor, engine, modules, and mounts. It supplements, but does not replace, the Ship's immediate operational status, location, fuel, cargo, and actions.

**Ship Offer**:
A Ship configuration currently available at a Shipyard. It is evaluated before purchase using the same capability vocabulary as an owned Ship, alongside its price and availability signals.

**Ship Component Health**:
Two distinct measures of a Ship component. Condition is repairable current state; integrity is permanent, non-repairable wear. Condition is an operational signal, while integrity and quality are lifecycle context.

**Flight Mode**:
The speed posture a Ship uses while travelling (DRIFT, STEALTH, CRUISE, or BURN). It is a Ship Readiness fact, distinct from its current navigation status.

**Extraction Yield**:
The commodity and quantity returned by a successful extraction action. It is immediate action feedback; Cargo remains the persistent record of goods carried by a Ship.

**Cargo**:
The goods a Ship holds, bounded by its capacity.

**Trade Good**:
A commodity that can be held as Cargo and bought or sold at a Market. Its symbol is the operational identifier; its name and description are human-facing context when returned.

### The game loop

**Listing**:
The live Market or Shipyard data available to a Ship at an on-site Waypoint.

**Market Signal**:
API-provided context for a trade good: its market role, supply, activity, and trade volume. It informs a trade decision alongside buy and sell prices. Only API-defined constrained states, such as scarce supply or restricted activity, imply caution.

**Contract**:
The in-game mission object returned by the SpaceTraders API (types PROCUREMENT, TRANSPORT, SHUTTLE), with a deadline and payment terms.

**Acceptance Deadline**:
The time a pending Contract stops being available for acceptance. It is distinct from the completion deadline and is the authoritative replacement for the deprecated Contract expiration field.

**Contract Reward**:
The staged payment terms of a Contract: credits paid on acceptance and credits paid on fulfillment. Both stages inform the decision to accept.

**Mission**:
Our term for a human-steered flow through the game: accept a Contract, gather and deliver its goods, fulfill it. Distinct from the API's Contract.
_Avoid_: quest, job, contract (for the flow)

**Leg**:
One step of a Mission (e.g., navigate to the asteroid, extract, sell).

**Cooldown**:
A forced wait after certain Ship actions (extract, survey, refine) before the action can be repeated.

**Arrival**:
The scheduled time a navigating Ship reaches its destination; until then the Ship is IN_TRANSIT and cannot act.

**Transit Route**:
The active journey of an IN_TRANSIT Ship between its origin and destination Waypoints. A System Map represents it as a dotted line rather than placing the Ship at either endpoint.
_Avoid_: ship position, current waypoint

**Off-System Ship**:
A Ship belonging to an Agent that is neither at a Waypoint in the Agent's headquarters System nor in an inter-System Transit Route. A System Map reports it separately rather than placing it in the wrong coordinate system.

**Deadline**:
A time limit imposed by the game (Contract acceptance/fulfillment). Must be persisted so the app honors it across restarts.
