# Supported simulator world controls

Issue #780 supplies **`world-control/v1`** in the private standalone world.
The implementation, fixtures, build inputs and test exports remain private.
This page is the public integration contract; it does not replace executable
revision/artifact pins or qualify an experiment.

## Authority boundary

Start an isolated world in `serve-controlled` mode with a read-only controller
secret file. Give every attempt a distinct world ID and controller credential.
Use an attempt-private network: no production credentials, databases or targets.
The controller can initialize time/scenario identity, inspect supported events,
advance time and export state. It cannot make Fleet decisions or perform game
mutations with its credential. Game tokens cannot call controller endpoints.
Legacy unauthenticated simulator inspection routes are disabled in this mode.

Gameplay remains **real HTTP under `/v2`**, using normal registration, starting
resources, game credentials and server-enforced request scarcity/429s. The
actual application retains all planning, allocation, execution and PostgreSQL
authority. Controller inspection does not spend or refresh gameplay quota.

## HTTP contract

All control paths are under `/_control/world/`, with a controller bearer token:

| Method/suffix | Contract |
| --- | --- |
| `GET contract` | Version, time units, limits, ordering and truthful coverage; available before initialization |
| `POST initialize` | Single-use pinned identity; 201, repeated initialization 409, invalid/unsupported fields 422 |
| `GET inspect` | Initialization identity, authoritative current time, earliest supported event or null |
| `POST advance` | Exactly `to_time` and `max_events`; synchronous atomic settlement followed by inspection/events |
| `GET export` | Versioned credential-free authoritative game state, RNG snapshots, limiter ledger, request order, settlement trace and state hash |

Initialization requires exactly `contract = world-control/v1`, `scenario_id =
generated-starter/v1`, a named `world_id`, explicit integer Unix `epoch_ms`, valid
`reset_date`, and `random_streams`. Streams are exactly `generation`, `gameplay`
and `external`, each carrying an `id` and integer seed. Generation and gameplay
are separate streams. The external stream is reserved/exported but **unused**
until scheduled background mechanics are implemented. No arbitrary world-state,
ship, credits or gameplay-policy injection is a controller API.

Time is integer seconds since the pinned epoch, not elapsed wall time. The
contract bounds each step to 3,600 seconds, each settlement to 1–256 events and
the world horizon to 1,209,600 seconds. Backward, fractional or out-of-bound
requests fail with 422. Advancing **past an earlier due event fails with 409**;
the caller must stop there. An insufficient same-time event budget also fails
with 409. Both failures leave time/state unchanged. Repeating a settled instant
does not create duplicate events.

## Arrival tracer bullet

Navigation uses the game's real HTTP mutation. The supported world scheduler
discovers Arrival from authoritative in-transit ships and settles without a
gameplay read. Controlled worlds have no early-arrival tolerance. Same-time
events settle consistently by `(due_time, class_priority, ship_symbol)`, with
Arrival priority 10. The export records event ordinals, due/settled timestamps
and the preceding gameplay request-log ordinal.

The application coordinator must first drain actual runnable and unresolved
work. It advances only to the minimum bot wake, capacity release, supported world
event or horizon, respecting the world's per-step bound. The world settles due
events **before the advance response**; only then may the coordinator release
bot wakes. A world endpoint cannot prove application quiescence or authorize
skipping the application's durable pending work.

## Export and limits of evidence

`authoritative-world-export/v1` omits credentials. It includes world state,
exported RNG state, game quota state, request order and settlement order.
Its `state_sha256` uses the declared deterministic Erlang external-term encoding,
not raw JSON bytes. Pin OTP and the executable artifact when comparing exports.
The same identity and serialized game/control sequence must reproduce the same
export; different geometry seeds provide a negative control. This is not a
cross-service checkpoint/restore API.

**Only navigation/Arrival is scheduled in this slice.** The contract explicitly
lists economic production, market progression, rival charting, cooldown, survey
expiry, contract expiry and reset as unsupported scheduled classes. Existing
economic updates can remain read-driven. A null next event means no pending
**supported** event, never complete economic coverage.

#787 must extend this event inventory, ordering, settlement, independent stream
use, coverage declaration and tests. Do not introduce a second clock or claim
economic equivalence from Arrival-only tests. Normal gameplay alternatives stay
available; this slice does not qualify their comparative economic fidelity.

Private EUnit/real-HTTP regression covers initialization, invalid input,
same-time/ordered Arrival settlement, no-skip/bounded advancement, access/world
isolation, request scarcity, identical replay and changed-seed divergence. A
separate CLI check exercises startup through the supported secret-file interface.
These bounded component checks are **not** actual-app/PG integration, artifact
boot qualification, protected-host capacity, first-gate or whole-period proof.
The earlier #778 artifact/inputs/receipts are preserved and are not relabeled as
this revision. Real experiments still require their own approved manifest.
