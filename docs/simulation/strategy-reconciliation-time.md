# Strategy reconciliation time (#782)

## Implemented boundary

This slice uses the supported `SpaceTraders.Clock` for Strategy reconciliation,
not a second planner or a replacement gameplay policy. The tested seams are
Evidence, Generation eligibility, Fleet Allocation and the production
DemandScheduler/Reconciler callbacks, with synchronous PostgreSQL-backed tests.

| Chronology | Owner and decision |
| --- | --- |
| Evidence | Acquisition `observed_at`, freshness, due/deadline/withdrawal/fulfilment instants already use Clock. Latest retained observations now break frozen-time ties by physical `inserted_at` before random UUID. Contract sourcing and Construction discovery use the same ordering. |
| Generation / Revision | Generation birth, Strategy-capable time, credit eligibility, retirement/fencing and immutable Revision activation use Clock. Schema timestamp generators preserve the existing second/microsecond storage precision. Freshness and its future-date check sample one instant per eligibility decision. |
| Allocation | Decision Episode, Portfolio and Commitment creation; outcome classification; supersession/unwind; and the 120-second buy-to-sell handoff use Clock. Existing Neutral Wait, structural-stall, Market reconciliation and Capacity Investment decisions already sample Clock. |
| Capabilities | Contract acceptance freshness/authority, Contract planning, Construction evidence/planning and refit supply/authority decisions use Clock. Generation Horizon retains its current-Generation, 30-second freshness and authoritative-reset requirements. |
| Wakes | DemandScheduler reconstructs persisted future/overdue demands and missed deadlines. Reconciler reconstructs current-Generation work on boot even without a Market location, and uses cancellable, reference-tagged recurring refreshes; obsolete messages cannot fork the timer chain. |

External Contract deadlines and server-reset timestamps remain authoritative game
facts: parsing and comparison do not shift or rewrite their values. Replacement
of a Revision still withdraws its old demands; reconstruction cannot resurrect
their authority. A new current-Revision demand may request the same overdue facts.

The buy-to-sell handoff's **producer and consumers** use the same instant:
`Intents.complete_cargo_intent/5` (receipt-backed or recovered completion) and
`complete_cargo_intent_without_transaction/4` (prevalidated Cargo completion)
write semantic `finished_at`, which allocation compares with its semantic cutoff.
These shared Cargo completion helpers also timestamp their sell/deliver/transfer
completions; other Intent terminal writers and schema metadata are not migrated
by this narrow fix. Authoritative game receipt timestamps are not rewritten.

## Intentionally physical time

- Authentication/sudo expiry, credential timestamps and actual DB/socket/authority
  liveness timeouts remain wall time. ResetReplacementBoot's authority retry waits
  for a physical PostgreSQL owner, not a gameplay deadline.
- Observation/Demand creation metadata and AllocationResultPointer creation are
  physical persistence bookkeeping. Observation freshness uses `observed_at`, not
  `inserted_at`. Retention order breaks ties only within one semantic instant.
- Registration attempt creation order remains physical, preserving the existing
  frozen-time recovery tie-breaker. Strategy draft edit timestamps and Operator
  identity/name-bank metadata are not gameplay freshness bounds.
- Outbox delivery metadata and API shadow telemetry retain physical chronology;
  the existing Outbox deliverer wake itself already uses Clock. Static World
  coordinates do not expire, so `World.waypoint_coordinates/2`'s projection-time
  argument cannot change coordinate eligibility.

## Proof and qualification boundary

Ordinary tests exercise real production callbacks and PostgreSQL with TestClock;
Req.Test replaces transport. They cover semantic Generation birth/credit expiry,
Horizon freshness and frozen-time ordering, Contract deadline boundaries, due-work
restart under a replacement Revision, stale refresh rejection, Neutral Wait
history, publication/outcome/unwind, trade handoff expiry, and paired native/
semantic refit and Construction production-transfer-delivery controls. Existing
scheduler tests additionally cover future waits, overdue deadlines, cancellation,
duplicate wakes and native-clock restart.

The handoff regression calls production `Intents.execute_action/4` through
recorded dispatch and Cargo completion, with receipt-backed and receipt-free
responses, at semantic dates both behind and ahead of physical time. Without a
continuation, the completed buy blocks unwind at completion and exactly 120
seconds; at 121 seconds it disappears from pending sell handoffs and unwind is
allowed. No completed Intent or `finished_at` is manufactured/repaired by the
test.

**This is not real-HTTP, complete-drain or full-world qualification.** Concrete
uncovered consumers prevent promoting these results into a broader supported
profile:

- `Contracts.DeadlineServer` arms authoritative Timeline deadlines through Clock,
  but is not a NavigationParticipant; its dynamic callbacks are not covered by
  the closed navigation profile's drain proof.
- Ship Intent schema timestamps and terminal writers outside the two Cargo
  completion helpers above, several Intent freshness consumers,
  MutationAttempts outcome `recorded_at`, and Mission Control evidence-age/
  availability projections still include wall-time chronology outside this
  selected reconciliation slice. In-process completion does not qualify their
  exported chronology or all root families.
- Emergency Stop/resume refresh cutoffs retain wall-time comparisons in
  FleetStrategy/Fleet; no semantic-time stop/resume profile is qualified here.
- API scarcity/retries belong to #783; complete dynamic drain and app recovery
  belong to #784/#785. This slice changes neither those owners nor shared Clock/
  Navigation interfaces.

No gameplay experiment, protected-host operation, capacity/full-period run or
private-source upload was performed. Any actual-runtime qualification requires
its separately approved execution manifest and bounded stopping rules. The
parent integration owns the full `scripts/verify` gate; targeted tests alone are
not that gate and do not close #782 or #677.
