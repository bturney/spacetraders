# SpaceTraders: Game

The Game context: vocabulary of the SpaceTraders game and of every Operator surface (Mission Control, Ships, Ship pages, player Grafana dashboards). Engine terms live in the Strategy engine context; see [GLOSSARY-MAP.md](./GLOSSARY-MAP.md).

## Language

### The player

**Agent**:
The in-game player identity created via registration (e.g., ORBITALIST). Registered under an Account via its AccountToken; carries its own AgentToken. Owns its own credits, fleet, contracts, and headquarters.
_Avoid_: player, user, account

**Stale Agent**:
A retained Agent whose AgentToken the game rejects with a definitive Server Reset mismatch, proving that its game-generation identity is invalid. Its Fleet remains fenced while Agent Replacement is unresolved.
_Avoid_: deleted agent, old agent, inactive agent

**Retire a Stale Agent**:
The local relinquishment of a Stale Agent's gameplay authority and reset-scoped resources after successful Agent Replacement. Its Fleet Generation and meaningful causal history remain attributable; retirement never deletes an Agent upstream.
_Avoid_: delete agent, abandon agent, deregister

**Operator**:
The single authenticated human who drives this deployment's dashboard and authorizes external application and delivery actions. Links an AccountToken and governs at most one current Agent, distinct from historical Agent and Fleet Generation identities.
_Avoid_: player, captain, user

**Mint**:
Creating a new Agent through registration with an AccountToken and a chosen symbol and faction. A new Agent begins with the game's default resources, not its predecessor's resources.
_Avoid_: sign up, create account (for the in-app action)

**Current Agent**:
The Agent this deployment presently controls, or the fenced predecessor whose Agent Replacement remains unresolved. Empty setup has no current Agent; retired identities are history, never alternative current Fleets.
_Avoid_: selected Agent, newest Agent, active tenant

**Agent Name Bank**:
The Operator's durable, ordered preferences for candidate Agent symbols. It supplies approved alternatives for Agent Replacement, not generated suffixes or evidence that a symbol is available.
_Avoid_: name generator, fallback suffixes

**Agent Replacement**:
Establishing a fresh Agent and Fleet Generation while relinquishing control of the predecessor and retaining Fleet Strategy and meaningful history. Server Reset replacement follows definitive reset evidence; voluntary replacement abandons a healthy predecessor without resetting its resources or deleting it upstream.
_Avoid_: reset Agent, restore Fleet, delete Agent

**Account**:
The external my.spacetraders.io account holding the AccountToken, which mints new Agents. The app stores it encrypted for the sole Operator's in-app minting; it is never used for game actions.
_Avoid_: agent account, signup

**Server Reset**:
The game's replacement of its world state, signalled to an AgentToken by a reset-date mismatch. It invalidates the affected Agent's in-game identity and local cached state.
_Avoid_: app restart, connection failure, token expiry

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

**Waypoint Modifier**:
An API-supplied caution condition affecting a Waypoint (e.g., RADIATION_LEAK,
CIVIL_UNREST, STRIPPED, or UNSTABLE), carrying a symbol, name, and description.
Show it with caution styling; the game supplies no severity ranking, so the app
must not infer one.
_Avoid_: debuff, penalty, severity

**Chart Provenance**:
The Agent and absolute time the game returns for a Waypoint's chart. It is
secondary context, not an operational condition. Its absence is unknown optional
data, not a claim that the Waypoint is uncharted; show only returned facts and
never placeholders for partial provenance.
_Avoid_: chart history, discovered-by

**Waypoint Grid**:
A structured, actionable view of Waypoints in one System. It is linked to the System Map: selecting a Waypoint in either view selects and highlights it in both.
_Avoid_: waypoint browser, waypoint list

**Galaxy Map**:
A future representation of multiple Systems. It requires a deliberate System discovery model and is distinct from the System Map.
_Avoid_: system map

**Headquarters**:
The Agent's home waypoint, where the Agent starts.

### Fleet and earnings

**Fleet**:
The collection of ships owned by exactly one Agent. Ships never span Agents.

**Fleet Generation**:
One Agent and its Fleet from establishment until retirement through Agent Replacement. A Fleet Strategy may govern successive Fleet Generations across Server Resets or voluntary abandonment; reusing a symbol never makes successive Generations interchangeable.
_Avoid_: restored Fleet, persistent Fleet

**Completed Round Trip**:
One bounded trade whose causally linked goods acquisitions have been fully disposed of through sales, including multiple purchases, partial sales, or transfers between Ships. Its Trade Margin may remain unknown even when its quantities and completion are proven.
_Avoid_: latest buy/sell pair, completed sale (when meaning the whole trade)

**Trade Margin**:
The sale receipts minus goods-acquisition cost of one causally linked Completed Round Trip. It excludes supporting fuel, refit, and other costs and is unknown when required monetary evidence is incomplete.
_Avoid_: all-in profit, Episode Cash Flow

**Net Earnings**:
The revenue of a bounded outcome contribution minus its attributable goods and supporting costs, including fuel where applicable. An exact result requires complete monetary evidence and supported cost attribution; it is distinct from Episode Cash Flow when money movements span unfinished work or multiple contributions. Fuel is attributed at purchase: a realized refuel charge belongs in full to the root Intent that issued it, hence its Fleet Commitment and original Strategy Decision Episode, even if the fuel is later burned on another trip; a coverage Intent's refuel is observation-only spending, never a trade's cost.
Storage: one "Earnings record" (`earnings_records`) per completed trade Commitment holds its Net Earnings; a storage name, not a Game term.
_Avoid_: Trade Margin (when supporting costs are deducted), Agent balance change

**Neutral Wait**:
A deliberate Fleet Allocation result when no worthwhile admissible Candidate Contribution currently exists and the evidence needed for re-evaluation has a durable future observation time. It requires no Operator action and remains one Strategy Decision Episode while its selected result and binding limitation are unchanged. It is distinct from objective infeasibility and Degraded Operation. Only Fleet Allocation reconciliation may establish one.
_Avoid_: idle, stalled, blocked

**Plan Health**:
The Operator-facing judgment of whether the Fleet is succeeding at its Fleet Strategy, from current conditions: on plan, small setback, off plan, or can't tell. It never asks the Operator to act. Stale or absent evidence makes it can't tell, never on plan; deliberate Neutral Wait is on plan.
_Avoid_: Attention, alert, needs action

**Attention**:
Retired Operator-facing summary that a Fleet condition needed Operator judgment. Nothing in an autonomous Fleet needs the Operator; Plan Health replaces it (ADR 0017).
_Avoid_: Plan Health (which never asks for action)

**Emergency Stop**:
Retired Operator-owned suppression of new gameplay mutations. Stopping the service is the kill switch (ADR 0017).

### Ships and cargo

**Ship**:
A vessel the Agent owns (e.g., ORBITALIST-1, class COMMAND). Travels between waypoints, carries cargo, consumes fuel, and is subject to cooldowns.
_Avoid_: vessel

**Ship Destination History**:
The five most recently used distinct Waypoints for one Ship, retained as persistent quick-select choices for future navigation.
_Avoid_: route history (which implies completed journeys), saved route (which implies a multi-Waypoint plan)

**Survey**:
Agent-scoped Operational Intelligence from a survey action, carrying a signature, size, expiration, and its Survey Deposits. It is usable for extraction until its expiration or an authoritative extraction response proves it exhausted; a Miner Job may use it at the matching extraction Waypoint before falling back to normal gathering.
_Avoid_: mining target, survey cache

**Survey Deposit**:
One resource symbol within a Survey. It describes the Survey's resource composition but is not independently usable for extraction.
_Avoid_: extraction opportunity, mining target

**Ship Readiness**:
The capability and condition information that determines what a Ship can do: flight mode, crew, frame, reactor, engine, modules, and mounts. It supplements, but does not replace, the Ship's immediate operational status, location, fuel, cargo, and actions.

**Fuel-independent Ship**:
A Ship whose authoritative fuel capacity is zero and whose navigation therefore has no refueling requirement. Its zero current fuel is a Ship Readiness capability, not fuel starvation; game responses remain authoritative for actual navigation eligibility.
_Avoid_: unlimited-fuel Ship, empty Ship

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

**Historical Contract**:
A Contract that is fulfilled or demonstrably expired and is no longer actionable. An unaccepted Contract expires after its acceptance deadline; an accepted Contract expires after its completion deadline. A missing or malformed deadline does not establish expiration.

**Acceptance Deadline**:
The time a pending Contract stops being available for acceptance. It is distinct from the completion deadline and is the authoritative replacement for the deprecated Contract expiration field.

**Contract Reward**:
The staged payment terms of a Contract: credits paid on acceptance and credits paid on fulfillment. Both stages inform the decision to accept.

**Contract Delivery**:
An action that removes a Ship's goods at a Contract deliver destination against an accepted Contract's outstanding requirements. The Miner Job performs it before selling the same good at a Market that is also a deliver destination, so deliveries are never crowded out by sales.

**Deliverable**:
The required goods a Contract still owes at a destination as required minus fulfilled units. The Miner Job tracks it from authoritative Contract state and never sells a good an active Contract still owes at the same destination.

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
