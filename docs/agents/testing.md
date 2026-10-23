# Testing

Gate checks and output contract: `lib/mix/tasks/verify.ex`.
Local verification fixes formatting, then fails at `format` until those edits are committed.
`scripts/verify` installs `.githooks/pre-push`, which blocks pushing unformatted files.
Polluted test DB (leftover rows break boot/fixtures) → `scripts/reset-test-db`; drops only this worktree's database.

## Runtime test lifecycle

- Runtime children: `start_supervised!(Quiesced.child_spec(child))` waits out
  open checkouts before stopping processes.
- Ship servers: `Quiesced.stop_ship/1` or `Quiesced.stop_all_ships/0`.
- Deliberate sender death mid-transaction: `RuntimeDeath.kill/2` asserts the
  resulting disconnect.
- Test clock and governor configuration is application-wide: run synchronously
  and restore configuration in `on_exit`.

## Opt-in diagnostics

These own their setup and teardown; ordinary discovery and the gate omit them.
Run only when changing the corresponding whole-runtime or HTTP boundary:

```sh
mix test test/diagnostics/runtime_qualification.exs --seed 0 --trace
```

Runtime qualification drives authenticated Strategy activation through production
planning and execution; keep deterministic regressions at their public seams.

The #821 S3 whole-runtime deterioration matrix is a standalone diagnostic, not
an ordinary discovered test. Run each combination of `steady_growth` /
`charted_expansion` and `before_buy` / `after_buy` separately; assertions and
owned-resource leak checks still fail the command. No ExUnit timeout override:

```sh
MIX_ENV=test SHIPYARD_PROOF_PRESET=steady_growth SHIPYARD_PROOF_ARM=before_buy SHIPYARD_PROOF_RECEIPTS=/tmp/opencode/841-receipts mix run --no-start test/diagnostics/shipyard_thesis_deterioration.exs
```

The ordinary `fleet_intents_test.exs` destination-spread regression covers the
irreversible-buy guard; it does not substitute for the four runtime receipts.

## Release and deployment verification

Separate required CI job. The deployment-script regression suite uses isolated
command doubles and needs only Python 3 and Bash, with no production access.
The remaining checks need Docker Compose and the pinned toolchain/deps:

```sh
python3 test/integration/deploy_host_test.py
test/integration/postgres_compose_test.sh
test/integration/release_boot_test.sh
test/integration/migration_repair_test.sh
```
