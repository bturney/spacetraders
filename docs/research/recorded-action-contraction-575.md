# Recorded-action contraction — #575

Base: `d1fbe94` on `opencode/kimaki-spec-502-integration`, after #566–#574
adopted the shared progression. Resumed from an interrupted session's
uncommitted WIP; no reset.

## Contraction

- Deleted `SpaceTraders.API.RecordedDispatch` (a delegating coordination
  surface). `API.dispatch_recorded/1` calls `Fleet.Intents.RecordedAction`
  directly for commit-boundary, send admission and transport authorization:
  the remaining lower-level admission responsibility.
- One `Intents.reconcile/5` entry for boot and live triggers. Deleted the
  separate `:boot` clause, `boot_intent/2` and `recover/4`; boot with no
  expected identity selects the Ship's unfinished owned Intent, everything
  else must match the event identity.
- One send path: `execute_action/4` → `RecordedAction.prepare/3` →
  `send_selected_action/3`. Deleted the `unified_action?`/`navigation_action?`
  allow-list, the legacy raw-dispatch branch in prepared resume, and the
  bespoke cargo dock dispatch/response handling.
- Proven-absent retry sends through `send_selected_action/3`, so retry
  responses and rejections use the first-dispatch continuation. Deleted
  `retry_under_current_claim/6`.
- Deleted unreachable per-family navigate/orbit/dock prerequisite branches in
  module and cargo advance (the shared navigation-kind clause precedes them)
  and five per-family `unresolved_*` predicates; any persisted in-flight action
  is unresolved evidence.
- `lib` diff: 4 files, +46/−206.

Evidence remains bound-proof authority; MutationAttempts remains
verdict/retry/fence authority; capability clauses keep operation-specific
judgment. No new service, queue or state machine.

`verify.boundary` now rejects, outside `fleet/intents.ex`/`api.ex`: direct
`API.dispatch_recorded`, any `API.RecordedDispatch` reference, caller-owned
`RecordedAction.prepare/prepare_retry/retry_authority`, and
`admit_send/authorize_transport/require_commit_boundary` outside `api.ex`.

## Verification receipt

Every shell sourced `scripts/_toolchain.sh`. Build:
`MIX_BUILD_PATH=<worktree>/_build_575`. Database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5575/spacetraders_575`
(container `spec-502-575-postgres`); boot port `PORT=4575`. Logs under
`/tmp/opencode/`; `.status` siblings record command and exit.

| Check | Result | Log |
| --- | --- | --- |
| Boundary rejects progression bypass | Red: exit 2 (0 of 4 violations); green in focused run | `575-boundary-red.log` |
| Boot/cooldown retry rejection uses first-dispatch continuation | Red: exit 2 (in-flight action retained); green: exit 0 | `575-retry-red.log`, `575-retry-green.log` |
| Cargo dock enters recorded progression with trade (characterization) | Exit 0; 105 tests (16 selected), 0 failures | `575-dock-progression.log` |
| Targeted command below | **Exit 0; 259 tests, 0 failures** | `575-targeted.log` |
| Canonical `scripts/verify` | **Exit 0; 951 tests, 0 failures**; models, inventory, boundary, `/health` 200 | `575-canonical.log`, `575-canonical.status` |

Targeted command: `mix test test/mix/tasks/verify_boundary_test.exs
test/spacetraders/owned_intent_recovery_test.exs
test/spacetraders/resource_recovery_test.exs
test/spacetraders/api/recorded_dispatch_test.exs
test/spacetraders/mutation_attempts_test.exs
test/spacetraders/ship_execution_durability_test.exs
test/spacetraders/recorded_ship_runtime_test.exs
test/spacetraders/fleet_refit_test.exs test/spacetraders/fleet_intents_test.exs
test/spacetraders/transfer_recovery_test.exs --seed 0`.

Direct ledger-invariant and capability tests remain. Tests formerly reaching
`RecordedDispatch` now reach `RecordedAction` (test code is outside the `lib`
boundary scan).

## Remaining risks

- Cargo dock rejection now blocks through the shared `block_intents/2`
  continuation rather than `block_cargo_intent/2`; covered by the shared
  continuation, not by a cargo-dock-specific rejection test.
- `RecordedAction` still lives under `Fleet.Intents` and is called from
  `api.ex` for send admission; the boundary check pins that one exception.
- Historical receipts (#504–#507, #566) still name `RecordedDispatch`; they
  describe past states and were not rewritten.
- #576 owns combined qualification; no production operation or gameplay trial
  occurred.
