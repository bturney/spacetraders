# Strategy, architecture and Fleet Allocation

> Imported from [#502](https://github.com/bturney/spacetraders/issues/502) on 2026-10-18. The contract text below is preserved from that issue without semantic edits. Qualification status is tracked separately; a written contract is not proof of implementation.

## Implementation Decisions

### Governing model and deep modules

ADR 0010 remains the architectural decision: one active BEAM modular monolith with PostgreSQL durable application truth. ADR 0007 remains the game-truth boundary. ADR 0011 governs one mutation recovery authority; ADR 0012 governs Neutral Wait. The source decisions are retained, not reopened or marked failed by ticket bankruptcy.

| Module | Small external interface | Sole responsibility hidden behind it |
| --- | --- | --- |
| Fleet Strategy | Read effective authority; draft, review, activate a revision; stop/resume | Validated objectives, ordering, constraints, Preferences, presets, revisions, Standing Authority |
| Fleet Generation | Reconcile lifecycle evidence and report the current Generation or genuine intervention | Reset fencing, replacement credentials and identity, minting, bootstrap, retirement |
| Fleet Planning | Evaluate Strategy and a versioned evidence snapshot into Candidate Contributions and evidence requirements | Objective-specific alternatives, outcomes, costs, uncertainty, preparation, and validity; no claims or execution |
| Fleet Allocation | Reconcile all candidates, current commitments, and governed resources into one portfolio delta or explicit disposition | Ordered protection, role matching, contention, retention, claims/reservations/pledges, dependencies, safe unwind, and Decision Episodes |
| Evidence and API Capacity | Require/withdraw evidence; admit a recorded mutation; report evidence and capacity dispositions | Provenance, demand fusion, contextual freshness, durable due work, dispatch, backpressure, adapters, and protocol limits |
| Ship Execution | Pursue/reconcile one bounded outcome under current authority | One root Intent, reusable prerequisite outcomes, waits, authoritative completion, attempt references, and scoped recovery |
| Mission Control | Authenticated commands into owners; read projections | Outcome-first presentation and navigation, without gameplay or coordination truth |

These are authority interfaces, not a mandate for seven new wrappers. Internal composition and existing modules may remain private. A pass-through disappears unless it has a real responsibility; a former mega-module is not replaced by callers that must know the same choreography.

```text
Operator -> Fleet Strategy -> versioned Strategy + evidence
                                      |
                                  Fleet Planning
                                      |
                          all Candidate Contributions
                                      |
                           one Fleet Allocation decision
                                      |
                       retained/new Fleet Commitments
                                      |
                Ship Execution / Fleet-level outcome owners
                                      |
                         Evidence and API Capacity
                                      |
                                SpaceTraders

Mission Control and observability <- durable outcomes and causal projections
```

### C01 — Explicit Strategy semantics and authority

Operational meaning is a validated, versioned domain representation, not a regular-expression interpretation of display prose scattered across capability modules. Objective identity, kind, scope, evaluation, horizon/target where needed, supported Hard Constraints, and Preferences have explicit semantics. Friendly labels remain presentation.

Existing Operator-authored revisions remain immutable. A compatibility interpretation must preserve their accepted meaning or expose an explicit limitation requiring refinement; it cannot reinterpret words opportunistically or silently add a new objective. Preset and recommendation changes affect drafts only. Supported constraints require enforceable consequence accounting; unsupported exact price/profit guarantees are rejected rather than approximated by a fixed safety allowance.

The active revision grants Standing Authority. Runtime singleton authority, current Generation, current Claim or authenticated Intervention, Emergency Stop, and every applicable Hard Constraint are revalidated before dispatch. Resuming a stop reconciles authoritative state and makes a fresh allocation decision.

### C02 — One coherent allocation decision

Every reconciliation considers relevant direct, supporting, preparation, acquisition, and current-retention alternatives from one explicit evidence/version context. Capability modules propose contributions or reconcile accepted outcomes; they cannot independently win by publishing first. Callback order and which capability woke the coordinator do not set Strategic Priority.

Allocation owns Ship role matching and the complete commitment portfolio. One busy or fenced Ship excludes only its affected resources and dependents. A current portfolio does not prevent acquisition, candidate comparison, or allocation to other Ships. Retain valid useful commitments; reconcile the smallest affected dependency subgraph. Do not discard selected compatible work by publishing only the first contribution.

Claims are exclusive; Reservations are bounded and accounted against authoritative resources; Pledges are backed by resources or explicit dependencies. Publication atomically binds the accepted delta, Decision Episode, resource protections, and outbox to the current Strategy, Generation, allocation, and relevant evidence versions. Stale proposals are recomputed, not opportunistically accepted.
