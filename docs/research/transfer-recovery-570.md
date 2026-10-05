# Two-Ship transfer recovery — #570

Initial source base: `17b28af5a518c0c5e4ea9f89152a1271dce71372`, integrating
#566 on fresh main `f36a20781c99f8849e75debac11355d61c0a8b4d`.

## Adopted interfaces

Transfer selection uses `Fleet.Intents.execute_action/4`; live responses,
prepared recovery and absence retries use the existing selected send/response
continuation. Deleted transfer's separate prepare/dispatch/response sequence
and `settle_transfer_attempt/4` timestamp/provenance/envelope construction.
Cargo-delta attribution and prerequisite judgment remain in Ship Execution.
MutationAttempts is the only durable outcome/retry/fence authority.

Evidence assembles the two exact Ship bindings through `recovery_proof/4`.
Each source covers only its own Ship, with Cargo and capacity validated from the
retained response. Transfer now requires retained sources even for direct ledger
submissions. Replacement observations are judged again; retained identity and
original acquisition time survive identical-fact replacement and restart reuse.

`RecordedAction.prepare_retry/4` adds optional `transfer_bindings: [source,
receiver]`; existing `/3` remains supported. It refreshes only admission source
references, retaining the selection ID and request. Selection fingerprints still
bind the exact refreshed evidence. Transfer request fingerprints exclude only
those two replaceable observation IDs, so a new acquisition cannot change the
admitted quantity, recipient, resource or Claims. Callbacks carry the committed
retry's selected action and attempt, rather than an earlier caller snapshot.

Existing admission revalidates both Claims, their identities and the receiving
Reservation. It additionally reloads the selected exact preflight observations
and checks Agent/Generation, age, identity, co-location, source Cargo and
receiving capacity at preparation, retry, marker and final transport admission.
It performs no reads from the game under those transactions. Losing retention
after the marker suppresses transport and preserves historical uncertainty.
Claim authority remains Fleet Allocation's; observation IDs are evidence, not
another allocation record.

`MutationAttempts.retire_unused_retry/2` generalizes existing stopped-retry
retirement to an admission-refused owner. Absence remains append-only truth;
permission retirement and matching selection retirement occur together. Accepted
effects can finish after receiver Claim loss, without restoring authority.

## Verification

All commands source `scripts/_toolchain.sh`. Private writable build:
`MIX_BUILD_PATH=/tmp/opencode/570-build`; prepared database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5570/spacetraders_570_test`;
boot `PORT=4570`; container `spec-502-570-postgres` (PostgreSQL 17).
Full transcripts are retained under `/tmp/opencode/`.

| Tracer / command | Actual result | Log |
| --- | --- | --- |
| Unretained direct transfer proof | Red: 1 test, 1 failure; ledger accepted fabricated coverage | `570-source-red.log` |
| Absence/live/boot progression | Red: 2 tests, 1 failure; no retry/completion | `570-progression-red.log` |
| Receiver Claim loss | Red: 3 tests, 1 failure; retry permission/selection retained | `570-revocation-red.log` |
| Bounded transfer uncertainty | Red: 4 tests, 1 failure; no bounded verdict | `570-bounded-red.log` |
| Partial expiry behavioral guard | Red: 6 tests, 1 failure; successful response completed with expired source | `570-expiry-behavior-red.log` |
| Refreshed retry proof | Red: 7 tests, 1 failure; expired preflight suppressed newly evidenced retry | `570-replacement-red.log` |
| Final receiving-evidence guard sensitivity | Red: 1 selected failure; exit 2 with guard disabled | `570-capacity-behavior-red.log` |
| Transfer, existing transfer judgments, owned recovery, recorded runtime and independent durability; `mix test ... --seed 0 --trace` | **94 tests, 0 failures; COMMAND_EXIT=0** | `570-targeted.log` |
| Initial `scripts/verify` | **831 tests, 0 failures; 250.0 seconds ExUnit; COMMAND_EXIT=0**. Compile, format, generators, transport boundary and port-4570 health boot pass. | `570-canonical.log` |

Earlier `570-expiry-red.log` and `570-capacity-red.log` were compile failures
from a missing Revision alias, not behavioral red evidence. The behavioral logs
above supersede them. Intermediate green logs ending in a compile failure or a
test failure are not qualification receipts. The final targeted run supplies all
green tracer results, including exact-source reuse across all four triggers,
retention failure and obsolete transfer callbacks. Existing #507 independent
PostgreSQL observer proofs remain intact in that run.

## Scope and conservative limits

Only #570's transfer family is adopted here. Unknown attribution becomes Bounded
Unknown only when the active Revision has no Hard Constraints; the endpoint's
bounded transfer quantity and zero credit spend are recorded explicitly. With an
active constraint that cannot be established from these Ship facts, the attempt
remains unresolved and fenced rather than fabricating accounting. The fence
covers the two actual Ship dependencies; unrelated Ships remain admissible.

Other capability adoption, #575 contraction, #576 combined qualification, the
separate worst-case spending-authority question and parent #502 Gates 2–5/live
trial remain their respective owners' work. No production/gameplay trial occurred.

## Current integration and final verification

Preserved the initial ticket implementation in `4ad83c8`, then merged integration
`01da1de90d6676e8982022da6f660ff8a7205a67` into this ticket branch. Integration
includes #567's Agent composite seam, #574's Fleet binding adoption and the
fail-fast gate (`mix test --raise`). This session did not modify integration.

Resolved the two shared conflicts by retaining the adopted-outcome documentation
and the union of direct retained-source requirements: navigation, refuel/jump,
Fleet purchase and transfer. #567's navigation action set and Agent-credit
binding/coverage, plus #574's Fleet source coverage and owner options, remain on
their established Evidence and Ship Execution seams. No second binding or proof
authority was added during the merge.

| Final post-merge command | Actual result | Complete log under `/tmp/opencode/` |
| --- | --- | --- |
| `mix test` the nine files below, `--raise --seed 0 --trace` | **172 tests, 0 failures; COMMAND_EXIT=0** | `570-integrated-targeted.log` |
| `scripts/verify` | **859 tests, 0 failures; 204.5 seconds ExUnit; COMMAND_EXIT=0**. Compile, format, both generator drift checks, transport boundary and port-4570 health boot pass. | `570-integrated-canonical.log` |

Targeted files under `test/spacetraders/`: `transfer_recovery_test.exs`,
`fleet_transfer_test.exs`, `owned_intent_recovery_test.exs`,
`fleet_acquisition_test.exs`, `fleet_intents_test.exs`,
`mutation_attempts_test.exs`, `recorded_ship_runtime_test.exs`,
`ship_execution_durability_test.exs`, and `api/recorded_dispatch_test.exs`.

No known #570 acceptance gap remains. Conservative unknown outcomes with
unproven active Hard Constraints remain fenced; this is not a claim to solve the
parent's separate spending-bound protocol or certify Gates 2–5. Combined
all-family qualification stays with #576.
