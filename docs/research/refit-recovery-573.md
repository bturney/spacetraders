# Refit recovery — #573

Base: `04758f5` on `opencode/kimaki-spec-502-integration`, including #567 and
#568. Rechecked #573 open, unassigned and `ready-for-agent`, then claimed as its
sole worker. The native #567 blocker remains open for PR closure; its predecessor
implementation was already integrated before this work began.

## Implemented boundary

Install/remove module and their purchase prerequisite now select through
`Fleet.Intents.execute_action/4`. Live responses, prepared boot recovery and
proven-absent retries use the shared selected-action continuation. Capability
logic still judges module/inventory deltas, docking, available slots, Cargo
space, current Market supply and price eligibility. Duplicate matching removal
still completes only when the authoritative installed-module count is zero and
Cargo contains the returned module; response quantity alone is insufficient.

Recovery uses `Evidence.recovery_proof/4` over exact bound Ship and Agent-credit
observations, preserving source identities and original acquisition times.
Module operations require retained sources even for direct MutationAttempts
calls without selection metadata. The refit purchase records pre-dispatch
credits so shared Market recovery can attribute the credit effect or prove
unchanged credits before retry. It does not introduce a new credit floor,
repricing rule or worst-case spending policy.

Deleted family dispatch/response preparation, the separate module settlement
ledger branch, constructed Ship-and-credit envelopes, latest-source timestamp
lookups, and family interruption/blocking helpers. Completion and refusal now
use the existing durable selection guard. A later observed module effect
withdraws unused absence permission rather than replaying the refit.

MutationAttempts remains final verdict/retry/fence authority. Claims, Generation,
Revision, Emergency Stop and singleton permission remain existing external
admission inputs; recorded commit and final-admission boundaries are unchanged.

## Verification receipt

Every shell sourced `scripts/_toolchain.sh`. Private writable build:
`MIX_BUILD_PATH=/tmp/opencode/573-build`. Prepared PostgreSQL 17 database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5573/spacetraders_573_test`.
Container: `spec-502-573-postgres`; canonical boot port: `PORT=4573`.
Transcripts below are under `/tmp/opencode/`.

| Check | Result | Transcript |
| --- | --- | --- |
| Exact original Ship/credit source across replacement and boot | Red: 2 selected failures from reacquisition; green: 2 selected passes | `573-exact-red.log`, `573-exact-green.log` |
| Direct module ledger requires retained proof, all three verdicts | Red: exit 2, 2 selected failures; green in refit run | `573-source-red.log`, `573-refit-green.log` |
| Newly observed effect retires unused absence permission | Red: exit 2, 2 selected failures; green: exit 0, 2 selected passes | `573-withdraw-red.log`, `573-withdraw-green.log` |
| Refit capability/progression tests | Exit 0; 21 tests, 0 failures | `573-progression-green.log` |
| Targeted regression command below | **Exit 0; 245 tests, 0 failures** | `573-targeted.log` |
| Canonical `scripts/verify` | **Exit 0; 947 tests, 0 failures; seed 866054; 211.9 seconds ExUnit**. Compile, format, generated models/inventory, transport boundary and `/health` HTTP 200 pass | `573-canonical-final.log`, `COMMAND_EXIT=0` |

The initial gate stopped at compilation: deletion left the now-unused
`DependencyKey` alias. `573-canonical.log` records exit 1. Removed that alias;
the subsequent canonical invocation above completed. There was one completed
full-suite gate, not repeated full-suite exploration.

Targeted command: `mix test test/spacetraders/fleet_refit_test.exs
test/spacetraders/fleet_planning_test.exs
test/spacetraders/owned_intent_recovery_test.exs
test/spacetraders/mutation_attempts_test.exs
test/spacetraders/ship_execution_durability_test.exs
test/spacetraders/recorded_ship_runtime_test.exs
test/spacetraders/api/recorded_dispatch_test.exs --seed 0 --trace`.

New owner cases cover live/prepared/absent one-effect progression, exact source
reuse across replacement, unused retry withdrawal, stopped absence retirement,
and Bounded Unknown historical acceptance during Emergency Stop. Bounded Unknown
accounting explicitly belongs to a zero-cost controlled-game fixture, not a
production exposure bound. Existing planner, duplicate-removal, 429 wake,
spending/admission, stale-callback and independent-durability tests remain.

## Adoption and remaining scope

Use `execute_action/4` for selection and shared response continuation; recovery
supplies the bound Ship to shared acceptance/absence progression and exact
Agent-credit binding. Retain capability judgment rather than reconstructing
ledger states or proof envelopes. No known #573 acceptance gap remains. #575
owns remaining all-family contraction and #576 combined qualification. #502's
separate spending-exposure decision, later gates and approved live trial remain
outside this receipt. No production operation or gameplay trial occurred.
