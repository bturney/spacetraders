# SpaceTraders

A dashboard + bot for playing SpaceTraders, a programmable API game where every action (register, navigate, mine, trade, buy ships) is an HTTP endpoint. This context covers the domain language shared by the Phoenix app, the dashboard, and the API integration.

## Language

### The player

**Agent**:
The in-game player identity created via registration (e.g., ORBITALIST). Registered under an Account via its AccountToken; carries its own AgentToken. Owns its own credits, fleet, contracts, and headquarters.
_Avoid_: player, user, account

**Stale Agent**:
A locally stored Agent whose AgentToken the game rejects with a server-reset mismatch, proving its in-game identity no longer exists. It remains marked until a successful replacement mint retires it, unless a same-symbol re-mint proves it can be replaced.
_Avoid_: deleted agent, old agent, inactive agent

**Retire a Stale Agent**:
The app's local-only removal of a Stale Agent and all of its cached state, credentials, ships, jobs, and scheduled work after a successful replacement mint. It never calls the game API.
_Avoid_: delete agent, abandon agent, deregister

**Operator**:
The human who drives the dashboard and authorizes external application and delivery actions. Links their own AccountToken once and may mint (own) one or more Agents. Distinct from the in-game Agent.
_Avoid_: player, captain, user

**Mint**:
Creating a new Agent in-app by calling the registration endpoint with an AccountToken and a chosen symbol + faction.
_Avoid_: sign up, create account (for the in-app action)

**Account**:
The external my.spacetraders.io account holding the AccountToken, which mints new Agents. The app stores it encrypted per-Operator for in-app minting; it is never used for game actions.
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

**Operational Intelligence**:
Observed facts about the game world that a Policy combines with authoritative Agent, Ship, Contract, and Job state to make decisions. Intelligence is scoped, may be partial or stale, and carries its source and observation time. It excludes goals, planned work, execution evidence, and the immediate state of owned entities.
_Avoid_: operational knowledge, world state

**Observation Demand**:
A revocable requirement for authoritative evidence, including its subject, required facts, acceptable freshness, deadline or expiry, and Fleet Strategy provenance. It may request Operational Intelligence or the immediate state of an owned entity. Compatible demands share one observation; it describes the evidence needed rather than prescribing an API request.
_Avoid_: poll, refresh job, API request

**API Capacity Governor**:
The Fleet-wide authority that admits and orders reads and mutations when API capacity is scarce. It combines compatible Observation Demands, protects safety and recovery work, applies Strategic Priority, and reports backpressure for Fleet reallocation. It is distinct from the raw rate limiter, which only enforces the API's protocol limits.
_Avoid_: rate limiter, request queue

**Waypoint Intelligence**:
Operational Intelligence about one Waypoint beyond its location and immediate navigability: construction status, modifiers, controlling faction, and chart provenance. Construction status and modifiers are operational state; faction and chart provenance are secondary context.

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

### Fleet

**Fleet**:
The collection of ships owned by exactly one Agent. Ships never span Agents.

**Fleet Generation**:
One Agent and its Fleet from successful minting until that Agent becomes stale
and is retired. A Fleet Strategy may govern successive Fleet Generations across
Server Resets; each replacement begins again from the game's default resources.
_Avoid_: restored Fleet, persistent Fleet

**Fleet Strategy**:
A durable, Operator-owned ordered portfolio of Strategic Objectives and meaningful hard constraints governing successive Fleet Generations. It records outcome-level intent rather than technical allocation settings, survives Server Resets, and leaves planning and tactical execution to the system; it never invokes game actions directly.
_Avoid_: fleet objective (for the complete strategic direction), automation

**Fleet Strategy Revision**:
An immutable snapshot of the outcome-level choices the Operator accepted for a Fleet Strategy, whether selected directly or through a preset. Each current Fleet has at most one active Fleet Strategy Revision. The active revision applies automatically to replacement Fleet Generations; recommendations and product changes never alter it silently.

**Strategy Decision Episode**:
A durable account of one Fleet Strategy reconciliation decision. It receives a stable identity when a plan is selected, preserves its original evidence references, compact provenance, and expectations, and accumulates outcome evidence until it is explicitly classified as realized, partially realized, superseded, reset-censored, or still evaluating. It connects the active Fleet Strategy Revision and objective evaluations to the evidence considered, admissible alternatives, binding constraints, selected plan, expected and actual outcomes, calibration version, and any later supersession. It is the causal join point for explanation and optimization, not a gameplay action or long-lived plan.

**Outcome Observability**:
Evidence of whether a Fleet Strategy is achieving its Strategic Objectives, including progress, economics, Fleet productivity, leaderboard movement, constraints, and expected-versus-actual outcomes. Mission Control summarizes it for the Operator; deeper analysis may use the observability platform.

**System Observability**:
Evidence of how the autonomous software behaves and performs, including planning, execution, API pressure, errors, latency, recovery, and resource use. It supports diagnosis and optimization and becomes Operator-facing only when it materially affects Fleet Strategy.

**Strategy-capable Time**:
Time during which the system can safely make progress on at least one Strategic Objective. It distinguishes useful autonomous availability from process uptime and excludes periods when faults or unavailable dependencies prevent all Strategy progress.

**Strategic Objective**:
One measurable outcome in a Fleet Strategy, with an ordered Strategic Priority, an evaluation rule, and a Fleet Generation, Strategy-lifetime, or recurring scope. An attain objective minimizes time to a target, a maintain objective protects a target with sufficient margin, and a continuous objective maximizes its outcome rate over a horizon.

**Strategic Priority**:
A Strategic Objective's position in the Fleet Strategy's ordered protection model. Under contention, the system protects a feasible plan for a higher Strategic Priority before committing remaining resources lower down; supporting work may proceed when it improves that protected plan.
_Avoid_: request score, task priority

**Candidate Contribution**:
An objective-specific planner's evidence-bound proposal for advancing a Strategic Objective. It declares expected outcomes, uncertainty, required roles and resources, dependencies, validity conditions, and alternatives without assigning Ships or acquiring resources. Fleet allocation accepts or rejects it as part of the whole commitment portfolio.
_Avoid_: task, request, Ship assignment

**Fleet Commitment**:
An accepted, evidence-bound promise to pursue an outcome contribution using declared claims, reservations, pledges, and dependencies. Fleet allocation maintains Fleet Commitments as a coherent portfolio; a commitment may coordinate one Ship, multiple Ships, or preparatory work, and is retained, superseded, or safely unwound at reconciliation boundaries.
_Avoid_: fixed plan, task, Job

**Claim**:
A Fleet Commitment's exclusive authority to use an indivisible Fleet resource or interval, such as commanding one Ship. A resource cannot support conflicting active claims.
_Avoid_: lock, assignment

**Reservation**:
A Fleet Commitment's protected share of a fungible Fleet resource, such as credits, Cargo capacity, or time margin. It is bounded by amount and evidence-valid horizon and releases when its justification no longer holds.
_Avoid_: budget (when referring to committed capacity), claim

**Pledge**:
A Fleet Commitment's promised quantity toward a divisible shared outcome, backed by sufficient claims, reservations, or explicit acquisition dependencies. Authoritative outcome progress, including progress caused outside the Fleet, reduces the remaining fulfillment rather than being treated as failure.
_Avoid_: reservation, fixed quota

**Shared World State**:
Mutable game state that may be changed by other Agents as well as this Fleet. An observation is evidence at a point in time, not a lock; Fleet planning records assumptions about it and refreshes them only when uncertainty can materially affect admissibility, expected value, or the next irreversible action.
_Avoid_: external interference, single-player state

**Hard Constraint**:
An explicit Fleet Strategy admissibility rule that the system may never knowingly violate. Uncertainty requires more evidence, a provably safe alternative, or escalation of a genuine contradiction; it never silently permits a violation.

**Preference**:
An Operator-owned choice that ranks plans already admitted by every Hard Constraint. Unlike a Hard Constraint, it may yield to a higher Strategic Priority or a better admissible outcome.

**Standing Authority**:
The continuing authority an active Fleet Strategy Revision grants the system to perform strategically justified gameplay actions whose possible consequences satisfy every Hard Constraint. Spending, irreversible consequences, and bounded losses do not independently require Operator approval; changing Operator-owned Strategy intent does.

**Safety Fence**:
A suppression of new mutations whose admissibility depends on unresolved evidence. It covers the smallest affected entity, resource, or commitment and every dependent reservation, pledge, plan, and mutation while unrelated admissible work continues.

**Bounded Unknown**:
An ambiguous mutation outcome whose worst possible consequence can be accounted for and remains inside every Hard Constraint. It may be retained as unresolved evidence without preventing unrelated or provably admissible work.

**Degraded Operation**:
Continued autonomous operation while a failing capability or API scope is quarantined. Unaffected planning, timers, telemetry, and admissible gameplay continue while recovery is retried at a sustainable rate.

**Emergency Stop**:
Durable Operator-owned state that suppresses every new gameplay mutation, including replacement minting, without cancelling actions already accepted by the game. Safety-critical reconciliation and observation continue; explicit resume starts from authoritative state and fresh planning.

**Ship**:
A vessel the Agent owns (e.g., ORBITALIST-1, class COMMAND). Travels between waypoints, carries cargo, consumes fuel, and is subject to cooldowns.
_Avoid_: vessel

**Ship Destination History**:
The five most recently used distinct Waypoints for one Ship, retained as persistent quick-select choices for future navigation.
_Avoid_: route history (which implies completed journeys), saved route (which implies a multi-Waypoint plan)

**Job**:
A durable, Operator-selected outcome for exactly one Ship. A Ship has at most one assigned unfinished Job. A finite Job declares completion criteria; a recurring Job maintains a condition or loop until paused, replaced, or stopped. Its Policy evaluates authoritative game state to choose an Intent; it never stores a fixed action script.
_Avoid_: automation, workflow

**Job State**:
The shared lifecycle of a Job. An active Job may be `active` while pursuing progress, `waiting` while progress is expected without intervention, `paused` by Operator choice, or `blocked` when changed circumstances or Operator action are required. A Job ends as `completed`, `failed`, `stopped`, or `replaced`; completion is an immutable historical result, and failure requires authoritative evidence that the outcome is impossible.
_Avoid_: status (when the lifecycle distinction matters), error (for blocked or failed)

**Job Blocker**:
A structured explanation of why a Job cannot currently progress. It records a stable reason, human-readable summary, evidence and observation time, who or what can resolve it, the condition for another attempt, and any corrective actions. A Job remains blocked while changed Operator input, capability, intelligence, resources, or future game state could permit progress; uncertainty is never failure.
_Avoid_: error, failure, message

**System Exploration Job**:
A finite Job that uses one Ship to establish baseline Operational Intelligence for every Waypoint in a fixed target System captured from the Ship's current System at assignment. The baseline requires a usable observation of identity, coordinates, type, orbital relationships, real traits, current modifiers, chart provenance when supplied, construction state, and Market composition. It acquires facts rather than following an exhaustive itinerary, opportunistically retains live Market Listings and other decision-specific volatile observations without making them completion requirements, and blocks with explicit unresolved coverage when no acquisition path remains.
_Avoid_: Explorer, System Survey Job

**Market Trading Job**:
A recurring Job that uses one Ship to repeatedly buy and sell up to an Operator-selected quantity of the Trade Good between the fixed source and destination Marketplaces selected from one Candidate Trade Route, within a fixed target System and Operator-confirmed financial constraints. It reconciles live prices before each purchase and sale, blocks when those prices no longer satisfy its constraints, and distinguishes estimated returns from realized results.
_Avoid_: Arbitrage Job, Trader

**Market Reconnaissance Job**:
A finite Job that uses one Ship to visit an Operator-selected ordered set of distinct known Marketplaces in one fixed System, record fresh Market Listings as Operational Intelligence, and complete once every selected Marketplace has been read. Completion does not consume the Ship's ability to configure another Market Reconnaissance Job. It derives candidate trade routes from those Listings but never buys or sells; a later Policy may use its observations to make trading decisions. Listings and candidates from completed stops remain available after completion as well as while the Job is active or blocked. It blocks with a Job Blocker when a selected Marketplace cannot be reached or read.
_Avoid_: market scanner, reconnaissance loop, trader

**Candidate Trade Route**:
A retained directional comparison of Listings for one Trade Good at two Marketplaces: source buy price, destination sell price, per-unit spread, and the observation time for each Listing. It is Operational Intelligence, not a commitment or estimate for a particular Ship; Cargo capacity, travel time, fuel cost, credits, and financial constraints belong to the Policy that may act on it.
_Avoid_: trade plan, profit forecast, arbitrage

**Procurement Job**:
A finite Job that uses one Ship to acquire a requested quantity of a Trade Good and deliver it to a specified Contract or Construction project, or sell it at a specified Market. It may accumulate and deliver the quantity across multiple purchases and trips within its sourcing and spending constraints.
_Avoid_: Delivery Job, Procurement and Delivery Job

**Construction Supply Job**:
A finite Job that uses one Ship to complete every outstanding material requirement for one fixed Construction project. It plans viable Cargo batches within explicit sourcing and spending constraints, reconciles shared Construction progress before each purchase and delivery, and completes when authoritative game state shows the project is complete, including when external deliveries finish it.
_Avoid_: Construction Job, construction workflow

**Policy**:
A Job's state machine for reconciling its target, constraints, progress, and authoritative game state. It decides that the Job is complete, waiting, or blocked, or selects the next viable Intent; it does not prescribe game API calls.
_Avoid_: script, action plan

**Intent**:
A state-aware request for one Ship to achieve a bounded operational outcome, such as reaching a Waypoint. Its caller owns authority to command that Ship; in autonomous operation that authority comes from a Fleet Commitment's Claim. One root Intent holds the Ship while it composes prerequisite outcomes internally and performs the necessary game actions; prerequisites never compete as separately active Intents, and the Intent is not a fixed sequence of API calls. It does not own Fleet-level allocation or multi-Ship coordination. Its active outcome chain, meaningful progress, and in-flight evidence survive app restarts so commands are reconciled rather than replayed.
_Avoid_: action, macro, script

**Intent State**:
The shared lifecycle of an Intent. An unfinished Intent may be active while it can progress, waiting for game state or time, or safety-fenced while unresolved mutation evidence makes further dependent work unsafe. It completes only when authoritative state proves its outcome, becomes infeasible when authoritative evidence proves its outcome cannot be achieved within the Fleet Commitment and Hard Constraints, or is superseded after safe unwind. Infeasibility returns to Fleet allocation for replanning rather than becoming an Operator approval request; unresolved game-action evidence prevents supersession.
_Avoid_: status (when the lifecycle distinction matters), error, Operator blocker

**Navigate Intent**:
An Intent to reach a requested Waypoint in the current or another System. From authoritative state it selects and performs the necessary Flight Mode, posture, refueling, local navigation, jump, warp, and wait outcomes within the caller's constraints. The caller supplies the destination and meaningful constraints rather than prerequisite choreography.
_Avoid_: Navigate Job, route script

**Ship Outfitting Job**:
A finite Job that uses its assigned Ship to satisfy a requested Ship Readiness capability with one of an explicit set of acceptable module symbols. It sources only within a fixed System and the Operator's spending, source, and removal constraints; it never removes an installed module without explicit permission or coordinates another Ship. It completes from authoritative installed-module state, blocks when changed input or resources could permit progress, and fails only when the Ship's immutable configuration proves the outcome impossible. Cargo supplied independently by the Operator may let a blocked Job resume.
_Avoid_: outfitting workflow, courier Job

**Refuel Intent**:
An Intent to restore a Ship's fuel where the game permits refueling. Its outcome handling is reusable as a root Intent or as a prerequisite within another Intent such as Navigate.
_Avoid_: fuel action (when referring to the state-aware capability)

**Acquire Waypoint Intelligence Intent**:
An Intent to establish a requested set of facts about one Waypoint. It reconciles existing and publicly available intelligence and may use scanning, navigation, charting, and on-site observation while retaining the provenance of every acquired fact.
_Avoid_: exploration script, visit waypoint action

**Buy Goods Intent**:
An Intent to acquire a requested quantity of a Trade Good from a specified Market within an explicit price constraint. It reconciles Cargo, credits, physical presence, and fresh Market Listings before buying.

**Sell Goods Intent**:
An Intent to sell a requested quantity of a Trade Good at a specified Market within an explicit price constraint. It reconciles Cargo, physical presence, and fresh Market Listings before selling.

**Deliver Goods Intent**:
An Intent to have a requested quantity of a specified Trade Good from Cargo authoritatively accepted by a specified Contract or Construction recipient. It reconciles Cargo, physical presence, and recipient progress before delivery.

**Miner Job**:
A durable Job that owns one configured local gather/sell loop for a Ship. It uses Policies and Intents to pursue the configured extraction Waypoint, Market, and Cargo threshold; it is the first concrete Job.
_Avoid_: mining bot

**Survey Job**:
A recurring Job that uses a survey-equipped Ship to maintain valid Surveys at one configured extraction Waypoint. It contributes Operational Intelligence without owning the Miner Jobs that may consume it.
_Avoid_: survey pass, scanner Job

**Survey**:
Agent-scoped Operational Intelligence from a survey action, carrying a signature, size, expiration, and its Survey Deposits. It is usable for extraction until its expiration or an authoritative extraction response proves it exhausted; a Miner Job may use it at the matching extraction Waypoint before falling back to normal gathering.
_Avoid_: mining target, survey cache

**Survey Deposit**:
One resource symbol within a Survey. It describes the Survey's resource composition but is not independently usable for extraction.
_Avoid_: extraction opportunity, mining target

**Sellable Cargo**:
The cargo a Ship holds that its configured Market will actually buy, determined by the Market's authoritative accepted goods (its imports and exchange lists). The Miner Job's Cargo threshold counts sellable cargo only.
_Avoid_: marketable goods, valuable cargo

**Gather Mode**:
How a Miner Job gathers on its configured extraction Waypoint: extract on mineral-bearing Waypoints or siphon on gas-bearing Waypoints. Chosen during configuration and revalidated against authoritative Waypoint and Ship capability.
_Avoid_: mining style, collection mode

**Manual Control**:
The Operator acting as an alternate caller of one-off Intents or direct game actions, not a Job or durable Ship mode. A manual command durably pauses the assigned active Job before it runs, and only one Intent actively commands a Ship. Manual execution survives app restarts; the Job remains paused afterward until explicit resume and revalidation against game truth. Outcome-level Intents are the default controls, while serialized posture-level actions remain available through progressive disclosure.
_Avoid_: Manual Mode

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
