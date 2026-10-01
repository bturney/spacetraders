# Recorded Ship dispatch — #504

## Qualified increment

`SpaceTraders.API.RecordedDispatch` owns preparation and send admission for the
initial orbit/posture action and its proven-absent retry. Ship Execution supplies
the selected outcome. `MutationAttempts` remains the only attempt/outcome ledger.

The starting point is accepted baseline `6d651d9c817bb10c6f5004363f464ddd95f37f96`,
on `feature/503-runtime-baseline`; fetched `origin/main`
`00a43d8fd47793bc2dc0555d806b678b870d25a6` was verified an ancestor before editing.
[Issue #504](https://github.com/bturney/spacetraders/issues/504) and
[#503's Operator-approved seam](https://github.com/bturney/spacetraders/issues/503#issuecomment-5923103174)
define the scope. ADRs 0010 and 0011 retain their owners and recovery authority.

```text
Ship Execution selected orbit outcome
            |
RecordedDispatch.prepare                 transaction / actual commit
  current authority + selection identity + prepared attempt + Intent linkage
            |
API capacity / protocol admission         no enclosing transaction
            |
RecordedDispatch.admit_send               transaction / actual commit
  current authority + selected attempt -> sent_or_unknown OR not_sent
            |
API transport                            no enclosing transaction
            |
MutationAttempts outcome                 same attempt, append-only history
```

Preparation gives each selection a UUID and atomically persists the action,
bound owner, Generation/Revision and Episode or authenticated Intervention
provenance, selected preconditions, expected effects, consequences, dependencies,
and `Intent.mutation_attempt_id`. Send admission reloads and locks current durable
authority, checks singleton and pending/durable Emergency Stop and reset fences,
checks exact selected action/linkage, Generation, Revision, Claim/version or
reserved authenticated Intervention, and atomically admits the prepared attempt
once. Orbit cannot spend credits or scrap a Ship; its applicable consequences
are checked against the current enforceable Strategy rules. Other mutation
adapters need their own consequence admission in #505.

Every recorded preparation, retry preparation and send rejects an enclosing
caller transaction explicitly. No network callback is used for orbit retry.
Transparent Req retries are disabled for recorded sends; a protocol rejection
is recorded under its one attempt rather than sending again with an old marker.

Proven absence consumes the original retry authorization and records/links the
new attempt in one commit under current selected authority. The original attempt
and its outcomes remain intact. Suppression records `not_sent` and its reason
without a send timestamp; prepared or sent history is never inferred from a
missing legacy attempt. Legacy action-without-attempt records are not backfilled.

## Proof and verification receipt

Full terminal evidence is retained under `/tmp/opencode/504-*.log`. Commands
source `scripts/_toolchain.sh`; Elixir has no separate configured typechecker,
so regular compilation uses warnings-as-errors. The final commit identifies the
qualified source tree; these receipts distinguish canonical and opt-in results.

| Command | Result | Retained log |
| --- | --- | --- |
| `mix test test/integration/runtime_baseline_proof.exs:163 --seed 0 --trace` before implementation | Exit 2; 2 tests, 1 failure, 1 excluded. Actual retry transport ran inside a transaction; independent observer saw no retry at send or after death. | `504-r2-red.log` |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0, repeated after implementation changes. | `504-compile-1.log` through `504-compile-5.log` |
| `mix space_traders.gen.models`; `mix space_traders.gen.operations` | Exit 0; generated 95 structs and inventory; generated contents unchanged. | Terminal output; freshness rechecked by canonical gate. |
| `mix test test/integration/recorded_ship_dispatch_test.exs test/spacetraders/manual_intervention_test.exs test/spacetraders/api/spec_conformance_test.exs --seed 0 --trace` | Exit 0; 23 tests, 0 failures; 8.9 seconds. | `504-recorded-admission-final.log` |
| `mix test test/spacetraders/intelligence_acquisition_test.exs test/spacetraders/manual_intervention_test.exs test/spacetraders/mutation_attempts_test.exs test/spacetraders/fleet_execution_test.exs test/integration/autonomous_runtime_scenario_test.exs --seed 0 --trace` | Exit 0; 64 tests, 0 failures; 29.1 seconds. | `504-independent-regressions-final.log` |
| `mix test test/integration/recorded_ship_dispatch_test.exs test/spacetraders/manual_intervention_test.exs test/spacetraders/mutation_attempts_test.exs --seed 0 --trace` after review | Exit 0; 30 tests, 0 failures; 9.8 seconds. | `504-reviewed-regressions.log` |
| `mix test test/integration/runtime_baseline_proof.exs --seed 0 --trace` | Exit 2; 1 test, 1 failure; 4.3 seconds. Retained C05/C06 trading qualification made zero purchases, retained 175,000 credits and 80 fuel, and rendered “Outcome status unknown.” This independent baseline limitation is not repaired or certified here. | `504-trading-opt-in.log` |
| `scripts/verify` | Exit 0; 718 tests, 0 failures; seed 260884; suite 131.7 seconds. Formatting, warnings-as-errors, 95 generated model files, operation inventory, transport boundary and `/health` 200 pass. No skips reported. | `504-canonical-verify.log` |

The ordinary runtime file now includes R2 without weakening its assertions, plus
first-send interruption, death inside atomic preparation, committed preparation
death before send, consumed retry interruption, concurrent sends, caller rollback,
and suppression after Claim, Generation, Revision, selection, singleton,
Intervention authority or portfolio version changes and Emergency Stop. Actual
sender/observer backends differ. For the final targeted R2 run, both send and
post-death snapshots retain the linked `sent_or_unknown` retry; game posture is
`IN_ORBIT`. Ordinary tests now discover these proofs; the inconsistent trading
case stays explicitly opt-in. The canonical R2 receipt uses sender/observer
backends **1822624 / 1822926** and retains linked attempt
`a7cd60e3-8f7d-4582-9cd9-9dade4361f17` at send and after death.

Sender-kill scenarios intentionally abandon volatile API capacity admissions.
Each isolated scenario restarts the real production Capacity Governor, as at
fresh VM boot. Runs before this isolation stalled after accumulated abandoned
admissions (`504-authority-retry-red.log`, `504-runtime-instrumented.log`);
individually run cases passed. This does not qualify process-only capacity
recovery or evidence-safe re-entry; those remain #506/#507 obligations. Existing
Intervention regression fixtures now carry a real Generation/Revision instead
of an invented active Revision id; their original behavior assertions remain.

## Review

`/code-review` ran once with independent Standards and Spec reviewers against
the complete staged change from `6d651d9`. Standards found no documented-rule
violations and two duplication heuristics: API admission choreography and Claim
binding. Both were consolidated in their existing owners. Spec found one
introduced compatibility problem: a rejected orbit's stale linkage hid the
following legacy navigation attempt. The runtime regression was confirmed red
(`504-review-linkage-red-3.log`); action clearing/replacement now clears linkage
atomically through the shared Intent writer, and the reviewed file passes. No
second review was needed for fixes within the original reviewed contracts.

## Cutover and compatibility

Migration `20261001010000` adds a nullable UUID foreign key on Intents and permits
`not_sent` ledger outcomes. Old rows keep null linkage and retain their unknown
history. New reads tolerate those nulls; no absence or retry permission is minted
by migration. Responses/outcomes remain in the existing ledger.

The old binary can ignore the added column but retains unsafe orbit retry and
does not understand `not_sent`. Binary rollback therefore requires admission to
stay stopped/drained. Migration rollback rejects remaining `not_sent` rows rather
than rewriting their truth. Retain the additive schema and recover forward.

Keep production admission stopped/drained until the complete accepted increment
qualifies #507 cutover. Remaining Ship caller adoption is #505; validated re-entry
is #506. This receipt does not authorize deployment, migration or live-game
operations. No production operations were performed.
