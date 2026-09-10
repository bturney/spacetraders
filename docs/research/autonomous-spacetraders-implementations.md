# Autonomous SpaceTraders Implementations and Operating Models

Research for [#298](https://github.com/bturney/spacetraders/issues/298), under
map [#297](https://github.com/bturney/spacetraders/issues/297), 2026-09-10.

## Executive Answer

The strongest public implementations do not converge on one architecture. They
do converge on a small set of domain-level separations:

1. **Strategy and execution run at different timescales.** Whyando expresses a
   reset phase as an `AgentEra` and emits a desired Fleet configuration;
   protoLabsAI runs deterministic Ship loops under a slower OODA strategy loop;
   Stafford Williams uses static Operator configuration and per-Ship decision
   actors. The dbagwell specification instead proposes a frequent global planner
   over resource controllers and scored work. These are different mechanisms for
   the same useful distinction: durable strategic posture should not be encoded
   as the next API call. [whyando eras](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L28-L42);
   [protoLabsAI two loops](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/docs/two-loop-fleet.md#L25-L64);
   [Stafford configuration](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/config.ts#L15-L38);
   [dbagwell planner/worker split](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L69-L103).
2. **Fleet coordination needs explicit ownership of scarce things.** The proven
   examples reserve credits, persist Ship assignments, reserve exploration
   targets, serialize planning, or keep a route unavailable to another hauler.
   The deepest specified model adds Ship/system claims, leases, generations,
   constraint keys, and same-pass pledges. The reusable idea is not any one lock
   or datastore; it is to name what is exclusive, what is shareable, when the
   reservation expires, and how it is reconciled. [whyando persisted state and
   ledger](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L56-L100);
   [protoLabsAI route reconciliation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/plan.py#L46-L83);
   [dbagwell claims](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L821-L871).
3. **Shared fulfillment differs from exclusive work.** A route or one-time
   negotiation can be exclusive. A Contract delivery or Construction requirement
   is divisible and should account for authoritative fulfilled units plus Cargo or
   plans already in flight. Whyando models pickup/delivery as atomic planner tasks;
   dbagwell explicitly specifies a multi-hauler pledge ledger rather than a single
   claim. [whyando task model](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/logistics-planner.md#L13-L27);
   [dbagwell contract pledges](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3003-L3026).
4. **Operational Intelligence is a Fleet input with acquisition cost and
   freshness.** Whyando generates market-refresh tasks whose value rises with
   staleness and shares persisted Surveys. protoLabsAI stations probes at active
   route endpoints and shares Surveys per extraction Waypoint. The dbagwell
   specification treats API calls as the binding resource and requires measurement
   by purpose. Intelligence is therefore neither free background data nor a private
   per-Ship cache. [whyando
   refresh tasks](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/logistics-planner.md#L29-L49);
   [whyando Survey manager](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/survey_manager.rs#L17-L49);
   [protoLabsAI probe stations](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/plan.py#L195-L232);
   [dbagwell API accounting](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L1347-L1375).
5. **Recovery quality is the largest differentiator.** Whyando and protoLabsAI
   read the reset date, while dbagwell specifies reset-keyed operation; only
   protoLabsAI publicly demonstrates automatic re-registration and selective
   epoch-state clearing. Whyando partitions data by reset and rehydrates its
   current Agent, Fleet, assignments, reservations, and ledger. dbagwell specifies
   persisted step/event recovery with supersession guards, but public runtime code
   is unavailable. Stafford's source keys entities and metrics by reset but does
   not prove unattended Server Reset completion, and SpaceShipIO reset awareness
   is unknown.
   [official Server Reset semantics](https://docs.spacetraders.io/server-resets);
   [protoLabsAI reset distinction](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/plan.py#L292-L300);
   [whyando startup](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L7-L26);
   [dbagwell recovery specification](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3891-L3906).

These findings are inputs to map #297, not an architecture selection. In
particular, none proves that an LLM, a VRP solver, a global tick, per-Ship actors,
PostgreSQL, Redis, or a workflow engine is required.

## Sources and Method

### Evidence rules

| Label | Meaning |
| --- | --- |
| **Proven** | Present in public source code, checked-in first-party documentation that points to that code, or the author's direct operating record. It proves the implementation at the cited commit, not universal correctness. |
| **Specified** | Required by a design/specification, but no public implementation or production record was available to verify it. |
| **Inference** | A bounded conclusion from several proven facts; called out rather than presented as behavior. |
| **Unknown** | The source does not establish the dimension. Absence from this review is not proof that private code lacks it. |

The review used primary sources only: the official SpaceTraders documentation
and OpenAPI repository; immutable commits from each implementation; the
implementation authors' own documentation and issue/commit history; and Stafford
Williams's first-party devlog. GitHub discovery results and project lists were
used only to locate candidates, never as evidence.

The official constraints matter when interpreting implementation choices. The
API applies both IP and Account limits of 2 requests/second plus a 30-request,
60-second burst and documents rate-limit headers and `Retry-After` behavior.
[Official rate limits](https://docs.spacetraders.io/api-guide/rate-limits). The
official reset documentation says resets wipe Agents, Ships, Cargo, and world
data, require a newly registered Agent, and advertise exact timing through the
status endpoint's `serverResets` field. [Official Server Resets](https://docs.spacetraders.io/server-resets);
[official status schema](https://github.com/SpaceTradersAPI/api-docs/blob/45fbb04130aca3fa0bd9a634ab77b35fa6c468ab/reference/SpaceTraders.json#L76-L227).

### Implementations selected

| Source | Why material | Evidence caveat |
| --- | --- | --- |
| [`whyando/spacetraders`](https://github.com/whyando/spacetraders/tree/234908ff2b176d76960b0ebeeb8c5a22a58fd122) | Active autonomous Rust Fleet covering trading, mining, Contracts, Construction, and exploration; detailed source-aligned operator docs; persistent economic and Operational Intelligence models. | Documentation describes a live deployment, but this review did not observe it running or validate its economic results independently. |
| [`protoLabsAI/spacetraders-plugin`](https://github.com/protoLabsAI/spacetraders-plugin/tree/c2a54942d2485dfe9419df2dbb72f00f51432249) | Autonomous multi-Ship engine with explicit strategy controls, test corpus, event bus, tripwires, Server Reset tests, and extensive first-party failure records. | It explicitly says it is a substrate demonstration, not a min-maxed bot; claimed yield improvements are author reports, not independently reproduced. |
| [`staff0rd/spacetraders-again`](https://github.com/staff0rd/spacetraders-again/tree/5af5da193309d11bd1a770066e402c1daffb3102) plus [author devlog](https://staffordwilliams.com/devlog/spacetraders-v2/) | A simpler 100%-automated actor-style baseline with production observability/deployment evidence and a first-party reset result. | Last public commit reviewed is 2025-03-25 and much code reflects an earlier game iteration; use it for operating-model patterns, not current API mechanics. |
| [`mcastae813/SpaceShipIO`](https://github.com/mcastae813/SpaceShipIO/tree/32d58e71d200f0f3aeb77b4eec7f968fec27ca02) | Low-code contrast: scheduled n8n workflows, Telegram operations, and a multi-Ship Mission Control node. | Hard-coded Waypoints and exported workflow JSON limit generality and line-level readability; no reset recovery or shared global rate allocator was found. |
| [`dbagwell00/spacetraders-spec`](https://github.com/dbagwell00/spacetraders-spec/tree/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32) | Deep, language-agnostic description of high-concurrency planning, ownership, API allocation, logistics, recovery, and telemetry. | The README says it is a point-in-time copy from a private Erlang workspace. Public evidence proves the specification exists, not that the described implementation or production measurements are reproducible. [README](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/README.md#L1-L8) |

Other located projects were omitted when they were API wrappers, interactive MCP
tools, notebooks, trading-only scripts, UI clients, or lacked enough public
source to establish Fleet-level autonomous behavior. Depth was preferred over a
catalogue.

## Implementation Evidence

### Whyando: Era-driven Fleet plus shared optimization

**Strategy and objectives (proven).** `AgentEra` is persisted and advances from
starter operation through a credits threshold and then completed home gate; the
current next inter-system era is explicitly unimplemented. Each controller tick
regenerates a desired `ShipConfig` list, buys missing slots, persistently assigns
matching Ships, and dispatches behavior-specific scripts. This is a reset opening
book and phase progression, not a general Operator-authored objective language.
[Era transitions](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L28-L42);
[Fleet convergence](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L56-L82).

**Assignment and orchestration (proven).** Ship slots state exact models,
purchase criteria, and behaviors. Assignment matches an unassigned Ship to the
first open slot of its model, so capability is mostly represented by purchased
model and configured behavior rather than dynamically matching all readiness
facts. The home configuration has probes, one surveyor, mining drones, mining
shuttles, Construction haulers, and logistics haulers; its comments record a
measured decision to retire siphoning as net-negative for the gate horizon.
[Fleet configuration](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/ship_config.rs#L26-L175);
[retired siphon slots](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/ship_config.rs#L222-L254).

**Logistics and shared fulfillment (proven).** A per-system
`LogisticTaskManager` generates profitable trade, stale-market refresh,
Shipyard refresh, Contract delivery, and Construction delivery tasks. A bounded
VRP solve considers one vehicle per Ship, Cargo capacity, travel cost, and task
value; pickup and delivery are one indivisible solver job. Planning is serialized
per manager, and an empty solver result falls back to the highest-value task.
[Task generation and solver](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/logistics-planner.md#L29-L74);
[per-Ship execution and serialization](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/logistics-planner.md#L76-L100).
Contract work receives a high task value, suppresses ordinary trade in the same
good, and can be fulfilled incrementally; the final payment is attributed among
Ships in proportion to units delivered. [Contract flow](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/contracts.md#L7-L33);
[Contract task priority](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/contracts.md#L42-L53).

**Producer-hauler and intelligence sharing (proven).** `CargoBroker` queues
producers and receivers by Waypoint and transfers matching Cargo FIFO up to the
receiver's capacity. [Cargo broker](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/broker.rs#L33-L63);
[matching loop](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/broker.rs#L109-L171).
Surveys are persisted, indexed by extraction Waypoint, scored by desired
deposits, and removed after expiry or rejection. [Survey manager](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/survey_manager.rs#L17-L49);
[selection/removal](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/survey_manager.rs#L52-L109);
[rejection handling](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/ship_controller.rs#L860-L872).
Market observations, not just changed values, are separately persisted, which
preserves evidence that a listing was checked and unchanged. [Database observation
model](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/database/mod.rs#L286-L425).

**Claims, budget, and API allocation (proven).** Exploration target reservations
are persisted and protected by a mutex. [Exploration reservations](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/exploration.md#L61-L72).
The Fleet ledger reserves credits per Ship and subtracts held Cargo cost basis
from the still-effective reservation; snapshots retain both across restart.
[Ledger model](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/agent_controller/ledger.rs#L1-L42);
[effective reservations and persistence](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/agent_controller/ledger.rs#L156-L189).
All API requests pass through a global 501 ms spacing gate and warn when the
queue exceeds ten seconds. It does not publicly show priority classes or
purpose-level allocation. [API pacing](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/src/api_client/mod.rs#L438-L458).

**Recovery, observability, deployment, and Operator experience (proven).**
Startup reads the status reset date, selects a per-reset PostgreSQL schema,
registers or restores the Agent token, then rehydrates Agent, Fleet, Contract,
reservations, ledger, and era. A panic in any Ship script exits the process and
Kubernetes restarts the pod; there is no per-Ship failure isolation. [Startup and
failure domain](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L7-L26).
The Operator receives a read-only JSON API and separate dashboard with Overview,
Ships, Markets, Construction, and Map views; the unauthenticated API is also an
inspection surface. Deployment is a container image and Helm release. [Control
surface and deployment](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/architecture.md#L66-L91).

### protoLabsAI: deterministic Fleet engine plus agentic strategist

**Strategy and objectives (proven).** A deterministic inner engine runs
Contracts, trade, mining, siphoning, and scouting. A slower OODA loop reads
telemetry and durable lessons and may make one strategy, knob, or Ship-pin change
per window. Goals include credits and Fleet size, with extensible verifiers. The
LLM is deliberately outside the API-action hot path. [Loop boundary](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/docs/two-loop-fleet.md#L25-L64);
[control surface](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/docs/two-loop-fleet.md#L66-L79);
[goals](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L317-L330).

**Capability assignment and coordination (proven).** Role classification reads
live Cargo capacity and mounts rather than Ship names; explicit Operator pins
override automatic classification but cannot create absent mining/siphoning
capability. A capital-base rule can draft the largest automatic miner to Contract
and trade work when no trader exists. [Role classifier](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/roles.py#L18-L58);
[partition and override rules](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/roles.py#L61-L128).
The persisted Fleet plan adds hysteresis, keeps one Contract lead, diversifies
haulers across routes, rotates saturated routes, and stations probes at the
active route endpoints. [Plan reconciliation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/plan.py#L46-L83);
[no-steal and rotation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/plan.py#L98-L191).

**Shared fulfillment, logistics, and intelligence (proven, with limits).** One
Contract lead executes each Contract, while other haulers trade; repeated
strikeouts temporarily demote the lead so an unworkable Contract does not idle
the best hauler. This is fallback, not multi-Ship Contract fulfillment.
[Contract lead policy](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L76-L83).
Construction uses one spare hauler per window, authoritative remaining materials,
live credits, persisted Cargo provenance, and carrier-first recovery after an
interrupted delivery. [Construction logistics](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L218-L272).
Probes populate a shared price map; Surveys are cached per extraction Waypoint
and can be consumed by every miner there, with expired/exhausted entries dropped
and plain extraction as fallback. The cache is process-local, so it does not
survive restart. [Survey operating model](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L180-L186);
[cache implementation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/fleet.py#L807-L850).

**Budget and API allocation (proven).** Every Ship coroutine shares one async
client and one lock-paced interval of 0.55 seconds. There is 429 backoff and a
bounded API-error tally, but no evidence of API purpose queues or explicit
explore/exploit shares. Concurrent spending is guarded by repeatedly reading
live Agent credits per purchase chunk and preserving a floor; this reduces but
does not make the check-and-spend atomic across Ships. [Client pacing](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/client.py#L31-L55);
[concurrent spend guard](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/fleet.py#L148-L205).

**Reconciliation, recovery, and operations (proven).** Ship jobs poll arrival
and cooldown state, and one Ship's exception is converted to a result instead of
killing the Fleet. This is state-aware looping, but not durable event-driven
step resumption. [Fleet isolation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/fleet.py#L46-L70);
[concurrent job wrapper](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/fleet.py#L118-L137).
The reset watchdog recognizes reset error `4113`, can re-register, keeps the
Operator's desire for autopilot to run, and clears epoch-specific plans, API
errors, high-water marks, gate facts, and Cargo provenance. [Recovery handler](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/fleet.py#L2320-L2369);
[re-registration](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/client.py#L334-L369);
[epoch clearing](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/watches.py#L110-L126).
The Operator surface combines reports, presets, knobs, per-Ship pins, a decision
log, dashboard, events, and eight live-state tripwires. Events are telemetry only
and failures cannot affect control flow. [Tripwires](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/watches.py#L1-L46);
[event contract](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/events.py#L1-L24);
[failure isolation](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/events.py#L41-L54).

### Stafford Williams: per-Ship decision actors and production telemetry

**Operating model (proven).** The source declares itself fully automated. A
startup scan keys data by reset date, hydrates Ships and Surveys, then starts
per-Ship decision loops. [README](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/readme.md#L1-L5);
[startup hydration](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/init.ts#L11-L40).
The command Ship applies a fixed priority: buy/spawn missing workers, perform
system reconnaissance, pursue Contract trade, then shuttle. Other Ships run
role-specific infinite decision loops that wait for arrival and reject a loop
making ten decisions in under two seconds. [Command priority](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/startup.ts#L31-L43);
[decision loop](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/decisionMaker.ts#L23-L60).

**Assignment and producer-hauler logistics (proven).** Roles are selected mostly
from registration role or frame symbol. Probe assignment is deterministic by
sorted Ship and Waypoint order; larger light freighters are split between
shuttling and trading according to Fleet count. [Worker assignment](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/spawnShipWorkers.ts#L26-L68);
[hauler split](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/spawnShipWorkers.ts#L85-L119).
A supply Ship waits at an extraction Waypoint, selects a drone carrying the
desired good, transfers up to free capacity, and delivers to the production
chain. There is no explicit reservation: selection sees mutable shared Ship
objects and relies on each Ship's `isCommanded` ownership plus serial actor
actions. [Supply actor](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/ship/actors/supply.ts#L24-L59).

**API budget, reset, and operations (proven/unknown).** Generated API functions
share a Bottleneck limiter configured for one concurrent call and 500 ms minimum
spacing. [Limiter](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/apiFactory.ts#L43-L94).
PostgreSQL entities and Influx measurements carry reset date, but automatic
minting after a Server Reset is not established in the reviewed commit. The
author reported just under 12 million credits for the 2024-04-09 reset and
directly identified market saturation and oversupply as the next control
problem. [Author reset report](https://staffordwilliams.com/devlog/spacetraders-v2/v2.12/).
Deployment uses Docker Compose with PostgreSQL, Redis, InfluxDB, Grafana, Seq,
and restart-unless-stopped; telemetry records credits, extraction, Market and
Shipyard transactions, Listings, and Contracts, tagged by reset and Agent.
[Deployment](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/docker-compose.yml#L1-L35);
[telemetry fields](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/influxWrite.ts#L18-L64);
[economic telemetry](https://github.com/staff0rd/spacetraders-again/blob/5af5da193309d11bd1a770066e402c1daffb3102/src/features/status/influxWrite.ts#L84-L168).

### SpaceShipIO: scheduled workflow contrast

**Proven.** Nine n8n workflows divide error handling, summary reporting,
Contracts, mining, market scans, posture/refueling, Telegram notification,
multi-Ship hauling, and Ship purchase. Their cadences range from 30 seconds to
10 minutes. [Workflow inventory](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/README.md#L6-L20).
The documentation designates one workflow as the sole navigation-state writer
and makes mining skip posture changes, reducing cross-workflow collisions.
[Writer boundary](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/docs/getting-started.md#L121-L147).
Mission Control reads all Ships and Contracts each tick, classifies mining from
mounts, skips in-transit/cooldown Ships, and stores a preferred Survey in n8n
workflow static data. [Mission Control](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/workflows/07-hauler.json#L80-L83);
[Survey store](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/workflows/07-hauler.json#L650-L656).
The Operator imports/activates workflows in n8n and receives Telegram summaries
and alerts. [Setup and activation](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/docs/getting-started.md#L66-L117).

**Limits/unknowns.** The Mission Control code hard-codes extraction and fuel
Waypoints, the agent token is manually configured, and a whole-Fleet tick can
exceed n8n's default 60-second task timeout. [Hard-coded control node](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/workflows/07-hauler.json#L80-L83);
[timeout requirement](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/README.md#L84-L94).
The same control node classifies all Cargo as junk when no Contract is active,
because `tradeSym` is then absent, and jettisons non-Contract Cargo once a Ship is
70% full without checking whether a Market would buy it. [Jettison policy](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/workflows/07-hauler.json#L80-L83).
No source-proven global API limiter, cross-workflow credit reservation, general
claims, event-driven arrival scheduling, or automatic Server Reset recovery was
found.

### dbagwell: high-concurrency specification, not public runtime proof

**Specified strategy and orchestration.** A roughly five-second planner reads
global state, resource controllers publish desired state and budgets, sub-planners
offer scored work, and a global matcher assigns the best candidate while workers
execute typed step sequences. Explore and exploit receive separate capital and
jump-fuel budgets. [Controller pattern](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L105-L143);
[planner tick](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L1052-L1131).
This expresses objectives through controllers and scoring policy, not through an
Operator-authored strategy schema; the control API offers overrides and halts,
but a complete Operator strategy language is unknown.

**Specified claims, reservations, and shared fulfillment.** Ship claims prevent
two controllers from issuing live work; system claims have holder indexes and
leases; generation/observed-generation identifies unstarted assignments without
a timeout. [Ownership protocol](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L821-L927).
Credit check-and-reserve is the sole exclusive mutation, while other state
converges. [Concurrency boundary](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L4615-L4672).
Contract delivery is intentionally multi-hauler: persistent cross-tick pledges
and same-pass reservations deduct already-spoken-for units from authoritative
remaining fulfillment. [Contract planner](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L2993-L3039);
[pledge reconciliation](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3085-L3117).

**Specified logistics and intelligence.** Trade routes are shared atomic
claims; failed Market/good pairs back off temporarily; idle Ships recover stuck
Cargo; stale prices induce explicit scan work rather than guesses. [Trade
invariants](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L2602-L2645).
Producer-hauler handoff uses durable TTL-bound Fleet signals and bounded waits.
[Signal/wait protocol](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3810-L3853).
Operational Intelligence includes Market observations, Surveys, travel-time
samples, competitors, and condition planes; source and freshness differ by
fact. [Shared registries](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L609-L645);
[Survey and competitor data](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L770-L788).

**Specified API allocation, reconciliation, and observability.** A dual-bucket
limiter classifies requests by purpose, uses three priority tiers, round-robin
within tiers, queue aging, and bounded 429 penalty/retry. [Rate limiter](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L4087-L4159).
Worker admission is separately prioritized by measured marginal value per API
call and each Ship is single-flight. [Worker admission](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3695-L3799).
Pending events, step index, metadata, and resume labels are persisted; boot
resumes the current generation and clears orphaned work. [Step recovery](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3891-L3929).
The specification also requires decision rows, API logs, conflict/stale-write
counters, controller timing, queue age, and a deterministic simulator for A/B
testing and fault injection. [Telemetry counters](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L790-L799);
[simulator method](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L4506-L4559).

**Unknown.** Public sources do not establish deployment topology, actual scale,
the reproducibility of production measurements embedded in the specification,
or which portions exist in running code. Its exact-once language also deserves
careful validation against ambiguous HTTP outcomes: persistence can prevent
local replay only when the external action's outcome can be authoritatively
reconciled.

## Cross-Cutting Comparison

| Dimension | Whyando | protoLabsAI | Stafford | SpaceShipIO | dbagwell spec |
| --- | --- | --- | --- | --- | --- |
| Strategy expression | Proven persisted eras plus code configuration | Proven presets, knobs, pins, goals, OODA lessons | Proven environment flags/counts and fixed command priority | Proven workflow definitions and hard-coded constants | Specified controller desired state, scoring, overrides, halts |
| Objective selection | Proven credits threshold and home-gate milestone; later era incomplete | Proven credits/Fleet-size goals; agentic choice within control surface | Proven mining/trade/Contract order; no general objective model | Proven fixed workflow loop | Specified gate/bootstrap, explore/exploit, viability and economics; no full Operator strategy schema |
| Multi-Ship orchestration | Proven concurrent Ship scripts plus shared per-system planner | Proven concurrent role jobs plus persistent Fleet plan | Proven per-Ship actors with command Ship coordinator | Proven whole-Fleet scheduled workflow | Specified global planner, bounded worker pool, per-Ship single flight |
| Capability-based assignment | Mostly model/slot based; configuration encodes required Ship type | Proven live mounts and Cargo capacity with safe override degradation | Mostly registration role/frame; limited capability inference | Mining laser and frame checks in control node | Specified role/config registry and candidate constraints |
| Claims/reservations | Proven credits, Ship assignments, exploration targets, task-manager mutex | Proven no-steal route plan and Ship pins; spending floor is not atomic reservation | `isCommanded` guards a Ship; no general target/credit claims found | One nav writer; no global claim system found | Specified Ship/system claims, leases, atomic route claims, credit reservations, constraint keys |
| Producer-hauler logistics | Proven Cargo broker and configured producer/shuttle cells | Shared Survey optimization; mining generally sells itself; Construction carrier recovery | Proven drone-to-supply-Ship Cargo transfer | Proven miner/hauler state machine | Specified durable signal/wait handoff and extraction drain work |
| Shared fulfillment | Contract/Construction tasks in shared planner; proportional Contract attribution | One Contract lead; one Construction carrier per window | Contract logic and supply actor, but no shared pledge model found | Shared Contract read; no durable pledge model found | Specified authoritative remainder minus cross-tick and same-pass pledges |
| Operational Intelligence sharing | Persisted Markets, observations, Surveys, galaxy, paths | Shared price map, route memory, lessons; process-local Surveys | Persisted Waypoints/Markets/Surveys and Influx history | n8n static Survey plus repeated scans | Specified shared GameState, provenance/freshness classes, conditions, competitor data |
| API-budget allocation | One global paced gate; no priorities found | One global paced gate; no priorities found | One global Bottleneck gate; no priorities found | Unknown global coordination across workflows | Specified purpose accounting, priority/aging, measured value admission; allocation controller remains partly observe-only |
| Event-driven reconciliation | Poll/tick plus per-Ship async waits; shared planning state persists | Polling coroutines; event bus is telemetry, not execution | Per-Ship arrival/cooldown waits | Cron polling | Specified persisted due-event scheduler and step resumption |
| Server Reset recovery | Per-reset schema and token registration/restore; full unattended transition not proven | Proven reset detection, re-registration, epoch clear, and run-intent preservation | Reset-keyed persistence; unattended re-registration unknown | Manual token setup; recovery unknown | Specified writer freeze until reboot and per-reset state; public runtime proof absent |
| Observability | Metrics, cash reconciliation, read-only API/dashboard, logs | Reports, decision log, events, dashboard, tripwires, error samples | Influx/Grafana, Seq, PostgreSQL, reset report | Telegram summaries/errors and n8n execution UI | Specified decisions, API log, gauges, conditions, conflict counters, simulator |
| Deployment | Kubernetes/Helm, PostgreSQL/TimescaleDB, separate SPA | protoAgent plugin; exact production topology not established here | Docker Compose, restart policy, five supporting services | Self-hosted n8n plus Telegram | Explicitly out of scope beyond architectural dependencies |
| Operator experience | Read-only dashboard/API plus environment overrides | Strategy presets, knobs, pins, goals, explanations, alerts | Environment configuration plus Grafana/Seq/data browser | Import/activate workflows and operate through Telegram/n8n | Control API for pause/scrap/navigate/halt/config; presentation unspecified |
| Routine intervention and escalation | Read-only surface; script failures restart the whole deployment | Per-Ship pins and tripwire alerts; ordinary fallback and replan behavior is partly proven | Logs/metrics expose failures; escalation boundary unknown | Telegram alerts plus manual workflow operation; escalation boundary unknown | Specified overrides and conditions; presentation and external-authority boundary unknown |

None of the reviewed systems proves the parent map's complete Operator boundary:
Strategy-level control without routine per-Ship Manual Control, autonomous
replanning for ordinary gameplay blockers, and escalation only for unavailable
external authority or contradictory constraints. The closest partial evidence is
whyando's read-only control surface, protoLabsAI's strategy controls plus per-Ship
pins and tripwires, SpaceShipIO's Telegram alerts, and dbagwell's specified control
API and condition model. [whyando control surface](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/architecture.md#L66-L91);
[protoLabsAI controls](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/docs/two-loop-fleet.md#L66-L79);
[SpaceShipIO operation](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/docs/getting-started.md#L66-L117);
[dbagwell controls](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L4432-L4490);
[map boundary](https://github.com/bturney/spacetraders/issues/297).

## Reusable Domain Patterns

These patterns do not select machinery for this project.

1. **Separate objective, allocation, and execution state.** An objective says
   what outcome matters and under which hard limits; allocation says which Ship,
   credits, Cargo capacity, target, and API budget are committed; execution says
   what authoritative state has been observed and what outcome remains. Eras,
   OODA windows, planner tasks, and actors are alternative implementations of
   those distinctions.
2. **Use different coordination semantics for exclusive and divisible work.** A
   Ship command, route opportunity, negotiator, or exploration target benefits
   from a claim with an owner and release/expiry rule. Contract and Construction
   fulfillment benefits from pledges against units remaining, because exclusivity
   would suppress useful parallelism. Reconcile both against authoritative game
   progress before purchase and delivery.
3. **Treat Operational Intelligence acquisition as schedulable work.** Retain
   source, observation time, scope, and completeness; distinguish "not observed"
   from "observed absent." Let stale or missing facts create a priced acquisition
   opportunity rather than a guessed value. Share Surveys, Market Listings,
   travel observations, and discovery across the Fleet when game scope permits.
4. **Allocate Fleet-wide constraints at Fleet scope.** Credits and Account/IP API
   limits are shared even when Ships execute independently. A reservation must be
   reduced or released as Cargo is bought, work completes, a claim is refused, or
   a plan is superseded. API telemetry needs purpose, queue demand, service, and
   stale-work age before an allocation policy can be evaluated.
5. **Persist intent and evidence selectively across two failure boundaries.** An
   app restart should preserve strategic intent, unresolved external-action
   evidence, assignments that still make sense, and future wakeups. A Server
   Reset should retain Operator strategy and durable lessons while invalidating
   Agent, Fleet, Waypoint, Market, Contract, Survey, and per-reset assignment
   identity. Reconciliation, not blind replay, decides the next action.

## Failure Modes and Trade-Offs

| Failure mode | Evidence | Trade-off or guardrail |
| --- | --- | --- |
| One Ship or planner panic takes down the Fleet | Whyando documents process-wide propagation. [Source](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/eras-lifecycle.md#L19-L26) | A restart supervisor is simple, but expands the failure domain and delays every Ship. Per-Ship isolation adds lifecycle/reconciliation machinery. |
| Planner invariants silently narrow legal game work | Whyando drops Contract destinations that are not in-system Markets and can panic when a planner starts off-Market. [Source](https://github.com/whyando/spacetraders/blob/234908ff2b176d76960b0ebeeb8c5a22a58fd122/docs/src/logistics-planner.md#L102-L112) | A specialized optimizer is powerful inside its model, but unsupported work must remain visible and replannable rather than look complete or impossible. |
| Concurrent work double-spends or over-fulfills | Whyando reserves credits; dbagwell specifies same-pass plus cross-tick fulfillment pledges; protoLabsAI repeatedly rechecks live credits but lacks an atomic reserve. | Strong reservation gives safety and explainability but needs expiry, unwind, and reconciliation to avoid phantom commitments. Live rechecks are simpler but leave a race between check and mutation. |
| A stale or dead claim idles capacity forever | Whyando persists assignments/reservations; protoLabsAI records route strikes; dbagwell specifies leases and generation gaps. | Durable ownership prevents collisions, but every ownership form needs a release signal, bounded lease, supersession rule, or health check. |
| Polling burns API budget or responds slowly | Whyando, protoLabsAI, and Stafford globally pace calls; SpaceShipIO polls several Fleet workflows on independent schedules with global coordination unknown; dbagwell specifies persisted due events. | Polling is simple and naturally reconciles, but cadence multiplies by Fleet/workflow count. Due-time scheduling reduces reads but requires durable wakeups and missed-event catch-up. |
| Priority harms its own dependencies | dbagwell records trade starving probes even though fresh Market data improved trade. [Source](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L3751-L3769) (**specified measurement**) | Fixed priorities are understandable but can starve Intelligence. Dynamic value allocation is adaptive but harder to measure, stabilize, and explain. |
| Heavy analytics block the control loop | dbagwell records a roughly 90-second query stopping planner ticks for eight minutes. [Source](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L1376-L1391) (**specified measurement**) | Keep expensive model updates off the command loop and hold the last valid policy on failure; eventual freshness is safer than a blocked actuator. |
| Market saturation erases nominal profit | Stafford observed declining profitability and oversupply; protoLabsAI adds route diversification, volume sizing, and rotation. [Stafford report](https://staffordwilliams.com/devlog/spacetraders-v2/v2.12/); [protoLabsAI damping](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L105-L108) | Stable assignments reduce churn but repeatedly hit one sink. Rotation/diversification spreads impact but may leave the best immediate route or synchronize without deliberate staggering. |
| A narrow objective destroys still-valuable Cargo | SpaceShipIO jettisons every non-Contract good when no Contract is active and all non-Contract Cargo at 70% fill, without a Market-value check. [Source](https://github.com/mcastae813/SpaceShipIO/blob/32d58e71d200f0f3aeb77b4eec7f968fec27ca02/workflows/07-hauler.json#L80-L83) | Preserve Cargo unless authoritative evidence establishes that disposal is strategically acceptable; freeing capacity is an allocation trade-off, not proof that Cargo is junk. |
| One objective creates pathological success | protoLabsAI states credits-only under-invests in Fleet and uses both credits and Fleet-size monitors. [Source](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/README.md#L317-L322) | Multiple objectives expose trade-offs but require priority and hard-constraint semantics; a scalar score can hide unacceptable sacrifices. |
| Reset recovery retains stale world identity or loses durable intent | protoLabsAI separates persistent run intent/lessons from cleared plans, route identities, and gate facts. [Source](https://github.com/protoLabsAI/spacetraders-plugin/blob/c2a54942d2485dfe9419df2dbb72f00f51432249/watches.py#L110-L126) | Clearing everything is safe but forgetful; retaining everything is dangerous. Every persisted fact needs an explicit reset scope. |
| "Exactly once" overstates what HTTP allows | dbagwell specifies effectively-once step effects, but no public runtime proof establishes mutation outcome reconciliation after every lost response. [Claim](https://github.com/dbagwell00/spacetraders-spec/blob/7a1dd73a27b6a8630bb3f6d48d44d2e2c5b93b32/SPEC.md#L4704-L4734) | Local event delivery guarantees do not settle an ambiguous remote mutation. Completion requires authoritative postcondition evidence or a safely idempotent operation. |
| Rich machinery exceeds the current Fleet's needs | SpaceShipIO coordinates useful work with workflow ownership and polling; dbagwell specifies PostgreSQL, Redis, controllers, workers, event store, and simulator. | Simple systems are inspectable and fast to alter but accumulate hard-coded assumptions. Deep coordination pays only when contention, scale, recovery, and optimization justify it. |

## Implications and Questions for Map #297

The map should answer these behavioral questions before selecting process, data,
framework, or deployment boundaries:

1. **Strategy contract:** Which objectives, Strategic Priorities, budgets, risk
   limits, deadlines, and hard constraints can the Operator set? Which are
   reset-spanning, and how are conflicts surfaced without silently rewriting
   Operator intent?
2. **Allocation contract:** What exact things can be claimed or pledged: Ship
   command, target, route, Cargo units, credits, API calls, Market impact, and
   fulfillment units? For each, define owner, scope, atomicity, expiry,
   supersession, unwind, and authoritative reconciliation.
3. **Intelligence contract:** Which Operational Intelligence facts are Fleet
   shared, how freshness/completeness are represented, what acquisition methods
   exist, and how API cost competes with direct progress? Unknown must remain
   distinct from false.
4. **Recovery contract:** For app restart, ambiguous mutation, and Server Reset,
   define retained intent, discarded identity, authoritative proof, replay rules,
   bootstrap milestones, and escalation conditions. Automatic minting needs its
   own evidence and safety boundary around stored AccountToken authority.
5. **Operator contract:** What summary explains objective progress, current Fleet
   allocation, binding constraints, projected reset outcome, stale intelligence,
   budget pressure, and autonomous replanning? What can the Operator change, and
   which changes take effect immediately versus at a safe reconciliation point?
   Keep per-Ship access diagnostic rather than routine Manual Control, require
   ordinary gameplay blockers to trigger autonomous replanning, and reserve
   escalation for unavailable external authority or contradictory constraints, as
   required by the parent map. [Map #297](https://github.com/bturney/spacetraders/issues/297).

The comparative evidence does **not** answer whether map #297 should use a
central planner, per-Ship processes, a solver, an LLM, event sourcing, PostgreSQL,
Redis, Kubernetes, or LiveView. It does show the questions those mechanisms must
answer and the failure modes against which prototypes can be evaluated.

## Evidence Gaps

- No reviewed public implementation demonstrates the complete target in map
  #297: Operator-authored reset-spanning Fleet Strategy, autonomous use of the
  entire API action surface, days-long operation, automatic Stale Agent retirement
  and minting, and principled escalation only for external authority or
  contradictory constraints.
- No common benchmark permits fair economic or API-efficiency comparison. Only
  Stafford provides a directly attributable reset result; protoLabsAI and
  dbagwell include author-reported results and measurement claims embedded in a
  specification, respectively, but this review did not reproduce either.
- Whyando's automatic transition across a live Server Reset is not documented
  end-to-end; Stafford and SpaceShipIO do not publicly prove it; dbagwell has no
  public runtime implementation. protoLabsAI has source/tests and explicit
  recovery logic, but no independently observed reset run was available.
- Purpose-level API-budget **measurement** is deeply specified by dbagwell, but
  dynamic explore/exploit allocation is explicitly deferred there. The proven
  implementations use one shared pace gate rather than a demonstrated strategic
  allocator.
- Public evidence is thin for generalized multi-Ship shared fulfillment beyond
  Contracts/Construction, reservation behavior under ambiguous API responses,
  and Operator handling of genuinely contradictory hard constraints.
