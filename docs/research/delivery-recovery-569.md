# Contract and Construction delivery recovery — #569

## Source and ownership

Started on integration `17b28af5a518c0c5e4ea9f89152a1271dce71372`, which
contains #566. Fresh `origin/main` was
`f36a20781c99f8849e75debac11355d61c0a8b4d`. Ticket implementation is
`6e51eda`; the verified integration merge is
`bb6e61318a28ae9fcdc48f9911318b5d9d421dd7`, including integration
`df1677ebc07ba04e586b212cf0a68d543e634b6c` (#567, #570, #574 and fail-fast
verification). This receipt's commit changes documentation only.

Contract delivery and Construction supply now adopt the existing root-Intent
`execute_action/4`, prepared re-entry, admitted retry and selected-response
continuation. Preparation, marker, final admission and outcome commits remain
independent; transport remains outside transactions. Existing concurrent retry,
revocation and independent PostgreSQL observer proofs still exercise the same
production protocol.

Deleted the two delivery-specific dispatch/response paths, the additional
Contract pre-send read, separate recipient/Cargo timestamp lookups and the two
hand-built reconciliation envelopes. Routing, prerequisite composition,
recipient validation, accepted quantity and external-completion judgment remain
Ship Execution responsibilities. Contract and Construction lifecycle ownership
is unchanged. MutationAttempts remains the only recovery authority.

## Interfaces and adoption

1. `Evidence.get_contracts(agent, bind: true)` returns the Contract list and its
   exact retained source in an existing `Evidence.Binding`.
2. `Evidence.get_construction(agent, system, waypoint, bind: true)` now does the
   same for the governed Construction read. Required Construction facts and the
   full decoded response are retained together; failed persistence is an evidence
   gap. Ordinary callers retain their decoded-value return shape.
3. `Evidence.retained_recipient_binding(agent, observation_id)` restores a
   particular retained Contract-list or Construction source without a game read.
   It preserves identity, fingerprint, Generation and acquisition time. Shared
   assembly and final ledger validation still determine eligibility.
4. `Evidence.recovery_proof/4` derives Contract coverage only from actual valid
   Contract progress entries, Construction coverage only from the matching
   retained resource/material facts, and Ship coverage from validated Ship facts.
   Neither Cargo nor the recipient is credited with the other's dependency.
   Direct delivery/supply ledger callers cannot strip these retained sources.
5. `Intents.execute_action/4` accepts `deliver` alongside the integrated
   navigation, refuel/jump and transfer families. The closed `unified_action?`
   continuation preserves all adopted families. Unsupported actions return
   `{:error, :unsupported_recorded_action}`.

Recovery compares exact Cargo and recipient facts against the selected baseline.
Matching effects settle acceptance; unchanged Cargo and progress permit a
still-authorized retry. Completed recipient progress with unchanged Cargo is
external completion: the attempt is absent, unused retry permission is withdrawn,
and root completion reports zero Fleet-earned units. Completion of the requested
material/deliverable is sufficient even before the recipient's overall completion
flag. Persisted absence rechecks this judgment before consuming a retry.

Missing/malformed/unretained supporting facts cannot settle uncertain attempts or
release their Safety Fences. A previously successful transport outcome also does
not bypass recovery fact validation to advance an unfinished root. Unknown legacy
dispatch history cannot be rewritten as absence merely because a recipient later
completed externally. Contradictory durable verdicts remain unresolved at the
root rather than fabricating a different effect or earned quantity.

## Verification

Confirmed public seams: Evidence binding/assembly, root Intents execution and
reconciliation, MutationAttempts invariants and the game HTTP boundary, following
the accepted #561/#562 contracts and #566 seam receipt.

All runs sourced `scripts/_toolchain.sh`. Private writable build:
`MIX_BUILD_PATH=/tmp/opencode/569-build`; prepared PostgreSQL 17 container:
`spec-502-569-postgres`; database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5569/spacetraders_569_test`;
private boot port: `PORT=4569`.

| Stage | Actual result | Full logs under `/tmp/opencode/` |
| --- | --- | --- |
| Contract exact composite source tracer | Red: 37 tests, 1 failure, 36 excluded; green: 1 selected pass | `569-contract-binding-red.log`, `569-contract-binding-green.log` |
| Construction binding/restart tracer | Red: 38 tests, 1 failure, 37 excluded; green: 1 selected pass | `569-construction-binding-red.log`, `569-construction-binding-green.log` |
| Construction exact-source progression | Red: 39 tests, 1 failure, 38 excluded; subsequent owner/outcome run: 68 tests, 1 existing external-completion fixture failure | `569-construction-progression-red.log`, `569-delivery-progression-green.log` |
| External completion attribution | Red: 41 tests, 2 failures; green: 70 tests, 0 failures | `569-external-completion-red.log`, `569-external-completion-green.log` |
| Persisted absence re-entry | Red: 42 tests, 1 failure; green: 42 tests, 0 failures | `569-retry-reentry-red.log`, `569-retry-reentry-green.log` |
| Missing material and malformed successful-response recovery | Missing material red: 43 tests, 1 failure; malformed boolean red caused an exception; final owner suite: 63 tests, 0 failures, exit 0 | `569-missing-material-red.log`, `569-success-gap-red.log`, `569-targeted-final.log`, `569-success-gap-green.log` |
| Merged delivery/credit/Fleet owner, outcome, runtime and independent durability suites, `--seed 0 --trace` | **172 tests, 0 failures, exit 0** | `569-integrated-targeted.log` |
| Actual transfer recovery and direct MutationAttempts suites, `--seed 0 --trace` | **27 tests, 0 failures, exit 0** | `569-integrated-ledger-transfer.log` |
| Final `scripts/verify` on merged implementation | **886 tests, 0 failures; COMMAND_EXIT=0**. Compile, format, generated-model/inventory checks, transport boundary and boot pass. | `569-canonical-integrated.log` |

The first merged targeted invocation included the nonexistent historical path
`test/spacetraders/transfer_execution_test.exs`; the separate 27-test invocation
uses the actual `test/spacetraders/transfer_recovery_test.exs` and
`test/spacetraders/mutation_attempts_test.exs`. The full canonical gate discovers
the real transfer suite. Earlier passing canonical evidence (`569-canonical.log`,
841 tests) predates the final malformed-success guard and integration merge and
is not the final verdict.

Coverage includes both recipient families and all four recovery triggers,
exact original Cargo lineage despite identical newer facts, exact-ID recipient
restart restoration, partial expiry/replacement, real Cargo/recipient retention
write failures, missing material facts, external completion with zero attribution,
prepared Construction dispatch, one retry, stale same-selection callbacks and
successful-response recovery with malformed recipient facts. Existing Contract,
Construction and independent dispatch outcome tests remain.

## Qualification boundary

#569's bounded recipient adoption is complete. Integration, remaining capability
adoption, safe compatibility contraction (#575) and combined qualification (#576)
are coordinator obligations. The separate spending-authority exposure blocker,
parent #502 Gates 2–5 and an Operator-approved multi-day live trial are not
certified by these tests. No deployment or gameplay trial was performed.
