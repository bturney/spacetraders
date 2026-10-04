# Navigation/posture recovery — #566

Source base: fresh `origin/main` and initial integration tip
`f36a20781c99f8849e75debac11355d61c0a8b4d`. This receipt belongs to the
commit containing it on `opencode/kimaki-spec-502-566`.

## Implemented boundary

Navigate, warp, orbit, dock and Flight Mode selection now use
`Fleet.Intents.execute_action/4`. Capability code supplies the selected outcome;
the root Intent owns preparation, dispatch, response continuation, reconciliation,
retry and retirement. Live dispatch and prepared boot recovery share
`send_selected_action/3` and `continue_selected_response/5`; retries carry their
own admitted Intent/attempt identity into that same response continuation.
Callbacks cannot clear a later retry of the same selection.

The existing admission implementation is now
`Fleet.Intents.RecordedAction`, under Ship Execution. Its preparation, marker and
final-authorization transactions and semantic telemetry are preserved; transport
still runs outside those transactions. `API.RecordedDispatch` temporarily
delegates to that implementation for adapters and not-yet-adopted families.
There is no second lifecycle record, service or recovery authority.

Deleted covered-action preparation/dispatch/continuation duplication, the parallel
boot read/retry progression, and navigation/posture timestamp/dependency/envelope
assembly. Capability-specific route, fuel, warp-range and outcome judgments stay
in Intents. Refuel/jump and other families retain their existing specialized
proof construction until their dependent tickets adopt the seam; #575 owns the
remaining compatibility contraction.

## Evidence and next-owner interfaces

1. `Evidence.get_ship_binding/3` returns `{:ok, %Evidence.Binding{value: ship,
   observation: persisted_source}}`. The read's own retention result supplies the
   source; there is no latest-observation lookup after acquisition. Persistence
   failure returns an evidence gap, even if the game returned decoded facts.
2. `Evidence.retained_ship_binding/2` restores a particular observation identity
   after restart without acquiring facts. `recovery_ship_binding/4` reuses an
   eligible supplied binding or performs one governed replacement read. Replacement
   facts require another owner judgment; reuse retains the original acquisition time.
3. `Evidence.recovery_proof/4` accepts attempt, owner outcome, attribution basis
   and bindings. It returns `{:ok, observations}` or `{:incomplete, %{usable: ...,
   unusable: ..., missing: ...}}`. Assembly never calls the game. Coverage comes
   from validated retained resource facts, not attempt dependencies or a conclusion.
4. `MutationAttempts.reconcile/4` independently reloads and validates each exact
   source, facts, fingerprint, Agent/Generation, resource-derived coverage and
   temporal requirements against the locked durable attempt before recording a verdict.
   Caller-supplied attempt snapshots cannot narrow required coverage or rewrite scope.
   Covered navigation operations
   require retained sources even when a direct ledger caller omits selection metadata.
5. Adopt later families by extending the existing source-derived coverage and
   closed action continuation in these modules. `get_agent/2` already accepts the
   owned-read `bind: true` option, but credit/recipient coverage and family adoption
   belong to #567/#569/#570/#571/#572/#574. Do not copy attempt dependencies into a
   conclusion, look up a later source timestamp, or introduce another proof workflow.

`Evidence.bound_ship/1` carries an ephemeral binding alongside decoded Ship state
inside Ship Execution and ShipServer. It does not alter generated models or
persist a second state machine. Exact-source comparisons and retention serialization
exclude that transport-only metadata. The additive migration records Generation
on authoritative observations. Existing unscoped observations remain retained;
they cannot support a Generation-scoped proof and recovery acquires a fresh source.

## Behavioral and independent durability proof

The public seams are Evidence binding/assembly, root Intents reconciliation and
execution, the MutationAttempts ledger, and the existing game HTTP boundary.
`owned_intent_recovery_test.exs` proves identical-fact replacement, exact-ID restart
reuse, retention-write failure, partial expiry, source stripping/false coverage,
wrong Generation, future/pre-dispatch/stale facts, all four recovery triggers,
same-selection obsolete retry callbacks, forged caller attempt scope and
accepted/absent/Bounded Unknown behavior.

The existing `recorded_ship_runtime_test.exs` and
`ship_execution_durability_test.exs` run through the moved production admission
implementation. Their separate PostgreSQL observers prove independent preparation,
marker and outcome durability, final-admission revocation ordering, interruption
recovery, eight-way retry/admission contention and unrelated Ship progress under
scoped fences. These guarantees were not replaced with telemetry-only assertions
or Sandbox visibility claims.

## Verification receipt

All commands source `scripts/_toolchain.sh`. Tests used private writable
`MIX_BUILD_PATH=/tmp/opencode/566-build`, prepared database
`DATABASE_URL=postgres://postgres:postgres@localhost:5566/spacetraders_566_test`
and canonical boot `PORT=4566`. The ticket-local PostgreSQL 17 container is
`spec-502-566-postgres`.

| Command / stage | Actual result | Complete transcript under `/tmp/opencode/` |
| --- | --- | --- |
| Exact-binding first tracer | Red: 1 selected failure, interface absent; green: 1 selected pass | `566-exact-red.log`, `566-exact-green.log` |
| Owned recovery replacement race | Red: 29 tests, 4 failures; all triggers lost original source lineage | `566-progression-red.log` |
| Independent runtime/durability + owned recovery, `--seed 0 --trace` | 73 tests, 0 failures | `566-targeted.log` |
| Source-stripping validator | Red: ledger accepted stripped source; subsequent root/source/boundary checks: 54 tests, 0 failures | `566-source-validator-red.log`, `566-source-validator-green.log` |
| Direct navigation ledger invariant | Red: 34 tests, 1 failure, unbound assertion accepted; green: 48 tests, 0 failures | `566-direct-ledger-red.log`, `566-direct-ledger-green.log` |
| Locked durable scope + current owned recovery/ledger/runtime/durability, `--seed 0 --trace` | Red: 36 tests, 1 failure, caller snapshot replaced required Ship scope; green: **91 tests, 0 failures** | `566-durable-scope-red.log`, `566-durable-scope-green.log` |
| `mix space_traders.gen.models`; `mix space_traders.gen.operations` | Generated contents unchanged; canonical drift checks also pass | `566-codegen.log` |
| Final `scripts/verify` | **Exit 0; 818 tests, 0 failures; seed 338656; 186.4 seconds ExUnit.** Compile, format, generated models/inventory, transport boundary and boot pass | `566-canonical-authoritative.log` (`COMMAND_EXIT=0`) |

The first gate exposed two old tests submitting unretained navigation conclusions
and the admission allowlist still pointing at the old API implementation.
Tests now supply real retained evidence; the allowlist replaces the old location
with the root-Intent implementation, without widening transport permission.
Retained earlier gates: `566-canonical.log` (815 tests, 3 failures, boundary failure)
and `566-canonical-final.log` (exit 0, 815 tests, before the final stricter direct
ledger guard and same-selection callback test).
`566-canonical-complete.log` retains the passing 817-test gate before the final
locked-durable-scope correction. That correction was driven by the independent
red case above, not by a green-only refactor.

## Qualification limit

This completes #566's enabling navigation/posture increment. Later capability
adoption, safe contraction and combined qualification remain their native tickets.
The separate worst-case spending-authority question and parent #502 Gates 2–5,
including an Operator-approved multi-day live trial, remain outside this receipt.
