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

**System Map**:
A visual, interactive representation of every Waypoint in one System, positioned by its game-supplied coordinates and showing the Fleet's current state.
_Avoid_: galaxy map, sector map

**Galaxy Map**:
A future representation of multiple Systems. It requires a deliberate System discovery model and is distinct from the System Map.
_Avoid_: system map

**Headquarters**:
The Agent's home waypoint, where the Agent starts.

### Fleet

**Fleet**:
The collection of ships owned by exactly one Agent. Ships never span Agents.

**Ship**:
A vessel the Agent owns (e.g., ORBITALIST-1, class COMMAND). Travels between waypoints, carries cargo, consumes fuel, and is subject to cooldowns.
_Avoid_: vessel

**Cargo**:
The goods a Ship holds, bounded by its capacity.

### The game loop

**Listing**:
The live Market or Shipyard data available to a Ship at an on-site Waypoint.

**Contract**:
The in-game mission object returned by the SpaceTraders API (types PROCUREMENT, TRANSPORT, SHUTTLE), with a deadline and payment terms.

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
