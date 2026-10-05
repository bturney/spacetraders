# Fleet acquisition exact retained recovery — #574

Source base: `17b28af5a518c0c5e4ea9f89152a1271dce71372`, including #566,
on fresh main `f36a20781c99f8849e75debac11355d61c0a8b4d`.
Implementation revision is the commit containing this receipt on
`opencode/kimaki-spec-502-574`.

## Owner boundaries and contraction

Fleet acquisition obtains bound owned Fleet and Agent observations through
Evidence, then supplies its existing registry-set-difference judgment to
`Evidence.recovery_proof/4`. Evidence derives coverage from the retained resource
subject and validated facts; MutationAttempts independently validates the exact
sources and remains the only verdict/retry/fence authority. Purchase proofs
without retained sources are refused even through direct ledger calls.

Deleted Fleet acquisition's timestamp/provenance/dependency envelope and
conclusion constructors. Its purchase eligibility, spending checks, attribution,
registration/readiness judgment and Decision Episode completion remain local.
Several unregistered Ships remain unattributable and fenced; valid observations
do not invent purchase attribution or a Bounded Unknown consequence bound.
Recorded transport/admission implementation is unchanged and Fleet acquisition
does not enter the Ship-scoped lifecycle.

`Evidence.recovery_fleet_binding/2` and `recovery_agent_binding/2,3` reuse eligible
retained components, preserving identity and acquisition time. Missing or
unusable components use the existing governed safety reads with retention
required. Proof assembly performs no reads. If a component expires while another
is acquired, assembly returns its existing incomplete result; the next recovery
replaces only the unusable component. Definitive Server Reset errors still go
through the existing Agent/Fleet Generation handler.

An accepted ledger outcome remains discoverable after an interruption before
readiness registration, so restart completes registration without another
mutation or rewriting the accepted outcome.

## Behavioral proof and verification

Confirmed seams: Fleet acquisition reconciliation/registration, Evidence exact
binding and proof assembly, MutationAttempts, and the game HTTP boundary.
The existing independent Ship protocol tests remain regression evidence for
the unchanged independent preparation/marker/admission commits and transport
outside transactions; Fleet acquisition tests do not claim independent Ship
dispatch durability by Sandbox visibility.

Every command sources `scripts/_toolchain.sh` and uses the private writable
`MIX_BUILD_PATH=/tmp/opencode/574-build`, prepared private
`DATABASE_URL=postgres://postgres:postgres@localhost:5574/spacetraders_574_test`,
and `PORT=4574`. PostgreSQL container: `spec-502-574-postgres`.
Full transcripts are retained under `/tmp/opencode/`.

| Proof / command | Actual result | Full log |
| --- | --- | --- |
| Exact retained purchase sources | Red: 1 selected failure, source nil; green: 6 tests, 0 failures | `574-binding-red.log`, `574-binding-green.log` |
| Partial-read restart reuse | Red: 7 tests, 1 failure, duplicate Fleet read; green: 7 tests, 0 failures | `574-reuse-red.log`, `574-reuse-green.log` |
| Owned subject coverage | Red: 8 tests, 1 failure, unrelated Fleet subject supplied coverage | `574-coverage-red.log` |
| Accepted outcome / registration interruption | Red: 9 tests, 1 failure, accepted attempt not discoverable | `574-registration-red.log` |
| Acquisition plus owned recovery, ledger, runtime and independent durability, `--seed 0 --trace` | Exit 0; 107 tests, 0 failures | `574-targeted.log` |
| Definitive Server Reset preservation with genuine game error | Red: 1 selected failure; green: 17 acquisition tests, 0 failures | `574-reset-confirmed-red.log`, `574-reset-green.log` |
| Final pre-integration `scripts/verify` | Exit 0; **829 tests, 0 failures**, seed 578219; 222.2 seconds ExUnit; compile, format, codegen/inventory, transport boundary and boot passed | `574-canonical-authoritative.log`, explicit `COMMAND_EXIT=0` |

The acquisition cases also prove exact source identity despite an identical
newer observation, failed Fleet/credit retention, stale/future/pre-dispatch and
wrong-Generation rejection, missing resource coverage, malformed credits,
source stripping, partial expiry with selective replacement, unattributable
multiple Ships, and ledger-owned Bounded Unknown accounting/fencing.

Earlier failed runs are retained: `574-proof-green.log` and
`574-proof-complete.log` exposed fixture setup constraints (existing rows when
adding a retention-failure constraint; duplicate Agent/Ship symbols).
`574-targeted-final.log` and `574-canonical-final.log` exposed the initially
abbreviated reset fixture, which was not definitive reset evidence. The genuine
fixture then independently demonstrated the handler omission red before green.

## Qualification limit

#574 covers Fleet acquisition's Evidence adoption only. No new spending policy
or purchase consequence bound is introduced. The ledger Bounded Unknown test
uses an explicit test-only constraint accounting example, not a production
worst-case exposure guarantee. Combined #576 qualification and parent #502
Gates 2–5, including the approved live trial, remain separate obligations.

## Current integration adoption and final receipt

Committed the ticket implementation as `e1baa67`, then merged current integration
`01702ee6a331e07d79cb9fc067a30b39fe5ccc5b`, including #567 and the canonical
verification gate correction, into this ticket branch. Integration itself was
not modified by this session.

Resolved the shared Evidence conflict onto #567's existing
`get_agent_binding/2`, `retained_agent_binding/2`, `recovery_agent_binding/2`
and Agent-credit coverage implementation. Deleted the parallel Agent decoding
and generic owned-component helper from #574. The shared recovery method now
also accepts optional owner options as `recovery_agent_binding/3`; existing
Ship callers retain their `ship_execution` default and Fleet acquisition
explicitly passes `owner: "fleet_reconciliation"`. Both families retain their
governed read ownership. Fleet binding uses the same eligible temporal query
pattern and the existing proof/source validation, without a new acquisition
workflow. Direct retained-source enforcement includes the union of navigation,
refuel/jump and purchase operations.

| Post-merge check | Actual result | Full log under `/tmp/opencode/` |
| --- | --- | --- |
| `mix test` acquisition, owned recovery, ledger, runtime, durability, Intents and RecordedDispatch files, `--seed 0 --trace` | **Exit 0; 155 tests, 0 failures**; 62.1 seconds | `574-integrated-targeted.log`, `COMMAND_EXIT=0` |
| `scripts/verify` | **Exit 0; 846 tests, 0 failures**, seed 109241; 204.8 seconds ExUnit; compile, format, generated models/inventory, transport boundary and boot pass | `574-integrated-canonical.log`, `COMMAND_EXIT=0` |

No known #574 acceptance gap remains. These receipts do not certify the combined
all-family qualification, production worst-case spending exposure, or later
parent gates.
