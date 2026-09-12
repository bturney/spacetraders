# Autonomous Runtime Architecture Validation

Research for [#310](https://github.com/bturney/spacetraders/issues/310),
2026-09-12. Repository context: branch `main`, HEAD
`03921abe3d877b5f2849508700a74cdcf66f47f3` (not committed by this research).

## Recommendation To The Parent Agent

Provisionally choose **Option A: a BEAM-owned modular monolith with PostgreSQL
as durable application truth**, constrained to one active autonomous runtime at
a time. Give BEAM processes liveness and short-lived, local serialization
authority only; give PostgreSQL durable intent/evidence/timer state; and treat
the SpaceTraders API as authoritative for game state and mutation outcome.
This fits the modest Fleet: per-Ship execution benefits from local process
isolation without paying for a distributed worker-lease protocol or a separate
workflow service. It is not a claim that a GenServer, a database transaction,
or a successful HTTP request is the source of game truth.

Use PostgreSQL rather than the current SQLite only if #309 selects it for the
target's durable shared state; this is an architectural decision, not a
requirement to retain the present persistence choice. The present
[ADR-0005](../adr/0005-async-time-per-entity-timers.md) design already supplies
the required shape: durable due events, process-local `send_after` wakeups,
boot re-arming, and overdue catch-up. It must grow from a timer record into
durable execution evidence before autonomous mutation is safe.

## Authority Boundaries

| Authority | Owns | Does not prove |
| --- | --- | --- |
| BEAM process | One currently live executor's mailbox, local order, cancellation, and wakeup | Survival of its state across VM loss; exclusive ownership across independently running nodes |
| PostgreSQL | Accepted Fleet Strategy revisions, claims, reservations, intents, dispatch/evidence records, due times, and generation history | That an external HTTP mutation happened or that cached game state remains current |
| SpaceTraders | Action eligibility, accepted mutation result, Ship/Agent/Contract state, reset invalidation, and shared-world facts | The application's intent, Strategy, or explanation of why it acted |

OTP supervisors restart children according to their restart specification, but
the restart begins from the child's configured initial state; process name
registration is removed when that process terminates. Therefore supervision is
a liveness mechanism, not persistence or cluster-wide fencing.
[Elixir Supervisor](https://hexdocs.pm/elixir/Supervisor.html#module-restart-values-restart)
[Erlang processes](https://www.erlang.org/doc/system/ref_man_processes.html#registered-processes).
Even distributed Erlang signals can be lost when the distribution channel goes
down, so it cannot by itself settle split authority.
[Erlang signal delivery](https://www.erlang.org/doc/system/ref_man_processes.html#delivery-of-signals).

## Non-Negotiable Mutation Protocol

For every gameplay mutation, commit an execution record with immutable
identity/request fields before
dispatch: intent/generation/entity identity, request fingerprint, precondition
evidence references, attempt number, and lifecycle state `prepared`. Atomically
transition it to `sent_or_unknown` before sending. Record accepted responses
and later classifications as append-only evidence, but
after timeout, connection loss, process death, deploy interruption, or reset,
do **not** infer failure or replay automatically. Re-read the narrowest
authoritative game resource, classify the intended outcome as accepted, absent,
or a [Bounded Unknown](../../CONTEXT.md#L169-L172), then either continue,
safely retry only when absence is proved, or fence dependent work.

HTTP defines automatic retry after a connection failure for idempotent methods;
it does not define `POST` as idempotent.
[RFC 9110 section 9.2.2](https://www.rfc-editor.org/rfc/rfc9110.html#section-9.2.2).
No local transaction can atomically commit with a remote HTTP server, so this
protocol remains necessary under all three options. Temporal explicitly expects
Activities that call external services to be idempotent because retries can
repeat them; its activity durability does not provide an idempotency key that
the SpaceTraders API honors.
[Temporal activity retry policy](https://docs.temporal.io/encyclopedia/retry-policies)
[Temporal idempotent activities](https://docs.temporal.io/activity-definition#idempotency).

This implements [ADR-0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md):
local checks and records may guard against known failure or uncertainty, but
cannot silently substitute for game eligibility or outcome. It also preserves
the `Intent` requirement that in-flight evidence survive restart rather than
be replayed ([CONTEXT](../../CONTEXT.md#L226-L231)).

## Options Compared

| Concern | A. BEAM liveness + PostgreSQL truth | B. PostgreSQL-coordinated stateless workers | C. Temporal durable workflows |
| --- | --- | --- | --- |
| Crash recovery | Restart/rebuild processes from durable records; reconcile `sent_or_unknown` before action. | Another worker claims durable work after transactional ownership recovery; same reconciliation protocol. | Service records Workflow history and regular Activity scheduling/completion; a replacement Worker replays workflow state. External activity ambiguity remains. [Temporal durable execution](https://docs.temporal.io/workflow-execution) |
| Duplicate authority | Straightforward on one VM. More than one active runtime requires a database ownership/fencing rule, not names or OTP alone. | Database is the authority boundary from the outset. A claim version can reject stale **database** writes, but cannot fence a SpaceTraders request already authorized by a stale worker. Reassignment must wait until any `sent_or_unknown` attempt is reconciled; the same remote-mutation protocol remains required. | A Workflow Execution has exclusive access to its local state, but Workers remain replaceable and Activities may retry; game-side reconciliation still required. [Temporal Workflow Execution](https://docs.temporal.io/workflow-execution) |
| Durable timers | Persist `due_at`; local `Process.send_after` is only an optimization. On boot query overdue/due work and re-arm. This is ADR-0005. | Atomically select/claim due rows; polling cadence and fair ordering are application-owned. `SKIP LOCKED` is appropriate for queue-like consumers but intentionally returns an inconsistent view. [PostgreSQL SELECT](https://www.postgresql.org/docs/current/sql-select.html#SQL-FOR-UPDATE-SHARE) | Workflow timer commands are recorded durably in history. [Temporal timers](https://docs.temporal.io/workflow-execution/timers-delays) |
| Single node / rolling deployment | Lowest operating surface with one active runtime. Deploy/shutdown is an expected recovery boundary: persist first, stop dispatching, then restart and reconcile. | Supports overlap and multi-node availability, but must implement lease expiry, contention, remote-dispatch ambiguity, and deploy-drain behavior correctly. | Durable Workflow code must stay replay-compatible unless a versioning strategy isolates it. Temporal recommends Worker Versioning for production, but says it is incompatible with rolling deployment; it requires blue-green or rainbow parallel versions. [Temporal Worker Versioning](https://docs.temporal.io/production-deployment/worker-deployments/worker-versioning) |
| Operational burden | Phoenix/BEAM plus PostgreSQL; boot recovery and observability are application work. | Same infrastructure plus work-claim schema, contention/backoff, stale-worker isolation, and queue operations. | Adds Temporal Cloud or a self-operated Temporal service, task queues, history retention, compatible deployment/versioning, and blue-green/rainbow parallel worker versions. Temporal calls self-hosting significant ongoing engineering and says its server is complex to run and scale. It also likely adds a non-Elixir worker runtime: Temporal's documented SDKs do not list Elixir. [Temporal production checklist](https://docs.temporal.io/self-hosted-guide/production-checklist); [Temporal SDKs](https://docs.temporal.io/develop) |
| Testing | Kill each owner and whole VM at each mutation boundary; assert boot recovery reconciles rather than resends. | Run competing workers; inject serialization failure, deadlock, lease expiry, and stale owner. PostgreSQL Serializable transactions require application retry after `40001`. [PostgreSQL isolation](https://www.postgresql.org/docs/current/transaction-iso.html#XACT-SERIALIZABLE) | Replay production-like histories and test incompatible code/deploy scenarios; Temporal documents replay as the compatibility check. [Temporal replay testing](https://docs.temporal.io/develop/go/testing-suite#replay) |
| Fleet-scale conclusion | Preferred: ships, timers, and API rate capacity are modest, while per-entity containment is useful. | Premature unless multi-active operation is a near-term availability requirement. | Premature unless durable multi-step orchestration and independent worker availability dominate the added service/runtime cost. |

PostgreSQL can coordinate database decisions: row locks release when the
transaction ends, advisory locks are application-enforced, and Serializable
transactions can abort with a failure the application must retry. Those
properties support B's claims/fencing protocol, but do not extend over HTTP.
[PostgreSQL explicit locking](https://www.postgresql.org/docs/current/explicit-locking.html)
[PostgreSQL Serializable](https://www.postgresql.org/docs/current/transaction-iso.html#XACT-SERIALIZABLE).
Ecto can compose database operations in a transaction and expose database
constraints/optimistic-lock conflicts; it does not change that boundary.
[Ecto.Repo transactions](https://hexdocs.pm/ecto/Ecto.Repo.html#c:transaction/2)
[Ecto optimistic locking](https://hexdocs.pm/ecto/Ecto.Changeset.html#optimistic_lock/3).

## Reset-To-Reset Operation Under A

1. On boot, load active Fleet Strategy, current Fleet Generation, unfinished
   claims/intents, mutation evidence, and timeline due events from PostgreSQL.
   Start a local owner only after it has reconstructed that entity's durable
   state; no owner dispatches from a blank process state.
2. Process each overdue event and `sent_or_unknown` mutation by authoritative
   read first. Arrival/cooldown timers re-read the Ship as ADR-0005 requires;
   dependent mutations remain safety-fenced until evidence settles.
3. Detect a Server Reset from authoritative game responses, retain the Stale
   Agent and its prior generation/evidence, and suppress its pending mutations.
   Mint the replacement under durable Strategy authority; only after a
   successful replacement mint retire the stale Agent's active credentials,
   Ships, Jobs, scheduled work, and cached state, while retaining historical
   generation/evidence. Bootstrap the new Fleet Generation. This follows the
   domain distinction between a Server Reset and an app restart
   ([CONTEXT](../../CONTEXT.md#L13-L18), [CONTEXT](../../CONTEXT.md#L101-L109)).
4. For a planned single-node deployment, stop admitting new mutations, let
   known responses persist, terminate processes, and use the same boot
   reconciliation. Do not rely on a graceful shutdown completing an HTTP call:
   a supervisor may forcibly terminate a child after its shutdown interval.
   [Elixir Supervisor shutdown](https://hexdocs.pm/elixir/Supervisor.html#module-shutdown-values-shutdown)

ADR-0004 is only weakly relevant: it chooses LiveView as the *manual* control
surface and rejects a bespoke CLI. It neither selects an autonomous runtime nor
provides process, persistence, timer, or deployment guarantees.

## Evidence That Would Overturn Option A

Replace A with B if measured or accepted product requirements establish **any**
of the following:

1. Two autonomous nodes must concurrently remain eligible to command one
   Agent/Fleet during a rolling deploy or node outage, and the recovery pause
   needed to maintain a single active runtime is unacceptable. This requires
   database-issued ownership versioning/fencing, not BEAM process registration.
2. Fleet measurements show one runtime cannot meet API-capacity governance or
   timer lateness objectives with the actual number of Ships and due events,
   after profiling the target workload. Scale, not a hypothetical large Fleet,
   would then justify partitioned database claims.
3. The product requires durable execution handoff and independent worker
   availability as a stated SLO, rather than restart-and-reconcile availability.

Replace A/B with C only if evidence shows a material class of long-running,
cross-entity orchestration whose durable replay, timer service, and versioned
worker deployment eliminate more implementation and operating risk than a
Temporal service plus non-Elixir runtime adds. Do not choose C merely for
ambiguous SpaceTraders mutations: Temporal Activities still require the same
external idempotency/reconciliation protocol.

Reconsider *all* options if the game adds an irreversible mutation that has no
idempotency key and no authoritative read capable of distinguishing its outcome
within the Strategy's hard constraints. That is an external-authority limit,
not a runtime-selection problem.

## Evidence Gap

The cited sources establish runtime guarantees and first-party production
deployment guidance. This repository has not yet measured its target Fleet's
Ship count, due-event rate, API capacity pressure, acceptable restart pause, or
availability SLO, and no applicable first-party production case study establishes
those values. Thus "modest Fleet" is a map premise, not external performance
proof; the recommendation is conditional on the measured thresholds in the
overturn conditions above.

## Verification Scope

Read before research: [CONTEXT](../../CONTEXT.md),
[ADR-0004](../adr/0004-liveview-as-control-surface-no-cli.md),
[ADR-0005](../adr/0005-async-time-per-entity-timers.md),
[ADR-0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md), and
issues [#297](https://github.com/bturney/spacetraders/issues/297),
[#309](https://github.com/bturney/spacetraders/issues/309), and
[#310](https://github.com/bturney/spacetraders/issues/310), each including its
comments (none were present at research time). External claims above cite their
owning standards bodies or first-party project documentation; no secondary
sources were used.
