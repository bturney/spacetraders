# Autonomous Fleet Strategy runtime

Status: Accepted

Date: 2026-09-13

## Context

The application currently combines a LiveView dashboard, SQLite-backed local
state, per-entity timers, Jobs, Policies, and Intents. Those choices support
Operator-directed automation, but they do not define how durable outcome-level
intent becomes coherent Fleet-wide action, how shared resources are allocated,
or how autonomous authority survives failures and Server Resets.

The target architecture needs one decision that governs that transformation.
It must preserve the authority boundary in ADR 0007 while replacing decisions
whose local, per-Ship implementation would otherwise constrain the autonomous
runtime.

## Decision

Build the autonomous runtime in place as a single-active BEAM modular monolith
backed by PostgreSQL. One active runtime owns autonomous coordination. Durable
application state is reconstructable from PostgreSQL; BEAM processes provide
serialization, wakeups, and fault isolation, not hidden persistence. The names
below identify architecture boundaries; domain records crossing those
boundaries use the vocabulary in `CONTEXT.md`.

The runtime has these authority boundaries:

- **Fleet Strategy** owns immutable Operator-authored revisions, Strategic
  Objectives, Strategic Priority, Hard Constraints, Preferences, Standing
  Authority, and Emergency Stop. It does not invoke gameplay.
- **Fleet Generation** owns Server Reset transitions, replacement minting,
  bootstrap, and retirement of reset-scoped state.
- **Fleet Planning** proposes deterministic, evidence-bound Candidate
  Contributions without claiming resources.
- **Fleet Allocation** owns the coherent portfolio of Fleet Commitments,
  Claims, Reservations, Pledges, dependencies, and safe unwind.
- **Evidence and API Capacity** is the sole route to SpaceTraders reads and
  mutations. It owns Observation Demands, evidence provenance, admission,
  backpressure, operation adapters, and protocol rate limiting.
- **Ship Execution** pursues one bounded root Intent for each claimed Ship and
  owns its prerequisite outcomes, waits, mutation attempts, and Safety Fences.
- **Mission Control** accepts authenticated Operator commands and renders read
  projections. It owns no gameplay or coordination truth.

SpaceTraders is authoritative for gameplay state, action eligibility, available
choices, and mutation outcomes. Local data records Operator authority,
application decisions, evidence with provenance, and conservative safety
bounds; it never substitutes for game truth. Successful mutation responses
update shared evidence immediately. Ambiguous mutations are reconciled from the
narrowest authoritative resource before dependent work proceeds or a retry is
admitted.

Every gameplay mutation has exactly one owner: registration belongs to Fleet
Generation, Fleet-level outcomes belong to Fleet-level reconcilers, and
Ship-scoped outcomes belong to root Intents. Every read satisfies a typed
Observation Demand. A generated capability manifest keyed by OpenAPI operation
ID will make this ownership and recovery classification executable and fail
verification when API coverage drifts.

Known waits persist `due_at`. Local process timers are disposable wakeup
optimizations; boot reconstruction and reconciliation derive from durable
state. A PostgreSQL-backed singleton autonomy lock suppresses new mutations if
the runtime loses authority. Generic job queues, brokers, distributed workers,
and the observability stack are not correctness dependencies.

Fleet Strategy and cross-reset decision history survive a Server Reset.
Credits, Ships, Contracts, Operational Intelligence, active work, and all other
game-generation state do not. Definitive reset evidence immediately fences old
Fleet Generation mutations. Successful replacement minting establishes the next
Fleet Generation and retires the old one; authoritative bootstrap then makes the
new Fleet Generation Strategy-capable.

Standing Authority permits strategically justified gameplay only when every
possible consequence satisfies all Hard Constraints. It never permits changing
Operator-owned Strategy intent. Emergency Stop durably suppresses every new
gameplay mutation while reconciliation, safety-critical observation, telemetry,
and history continue.

## Superseded and reaffirmed decisions

- **ADR 0002 is superseded for the target runtime.** PostgreSQL, not SQLite, is
  the durable application store. SQLite remains only during migration and as a
  cutover rollback artifact.
- **ADR 0004 is superseded where it frames the dashboard as a per-Ship manual
  control surface.** LiveView remains the initial Mission Control adapter, but
  routine gameplay is governed by Fleet Strategy and Standing Authority.
- **ADR 0005 is superseded in its timer ownership, SQLite persistence, and
  per-entity scheduling decisions.** Durable waits store `due_at`; process
  timers may wake reconcilers but do not own correctness.
- **ADR 0007 is reaffirmed and remains the gameplay authority boundary.** This
  record extends that boundary into autonomous planning, admission, execution,
  and recovery without weakening it.

Until a replacement phase is activated, existing code may continue to implement
the superseded records as legacy behavior. That code is migration evidence, not
the target architecture. Each delivery phase must preserve one gameplay
authority, separate prefactoring from authority activation, remain deployable
and observable, and define a rollback or forward-recovery boundary.

## Consequences

- Jobs, Policies, direct API paths, and current Intent execution are temporary
  migration structures rather than permanent parallel authorities.
- PostgreSQL migration and operation-adapter seams precede autonomous authority
  activation; the architecture does not justify a flag-day rewrite.
- Normalized current state is paired with compact append-only causal evidence,
  not full event sourcing.
- Missing responses, API pressure, outages, and Shared World State changes are
  normal reconciliation inputs. They narrow Safety Fences or trigger replanning
  instead of defaulting to Operator approval.
- Architecture checks must point to this record and eventually enforce the
  capability manifest, one mutation owner, governed reads, and removal of
  legacy entry points as their replacement phases become active.

## References

- [ADR 0002](0002-sqlite-local-state.md)
- [ADR 0004](0004-liveview-as-control-surface-no-cli.md)
- [ADR 0005](0005-async-time-per-entity-timers.md)
- [ADR 0007](0007-game-truth-and-quality-of-life-guardrails.md)
- [Issue 312](https://github.com/bturney/spacetraders/issues/312)
- [Issue 313](https://github.com/bturney/spacetraders/issues/313)
