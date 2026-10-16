# Testing

Gate checks and output contract: `lib/mix/tasks/verify.ex`.
Local verification formats files; include those edits.

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
mix test test/diagnostics/outcome_http.exs --seed 0 --trace
```

Runtime qualification drives authenticated Strategy activation through production
planning and execution; keep deterministic regressions at their public seams.
The HTTP diagnostic owns an ephemeral listener; ordinary tests bind no port.

## Release and deployment verification

Separate required CI job; needs Docker Compose and the pinned toolchain/deps:

```sh
test/integration/postgres_compose_test.sh
test/integration/release_boot_test.sh
test/integration/migration_repair_test.sh
```
