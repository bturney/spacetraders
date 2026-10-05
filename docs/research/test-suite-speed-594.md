# Test suite speed audit — #594

Question ([#594](https://github.com/bturney/spacetraders/issues/594), map
[#591](https://github.com/bturney/spacetraders/issues/591)): why is ~254s of the
~277s suite synchronous, and how far can the full gate's wall time fall?

Answer: the time is mostly not sync contention. **Two items sleep or re-run
for ~160s of the ~270s**: one test re-runs three other test files four times in
a child VM (72s), and Req's default retry backoff (1s/2s/4s) is played out for
real in ~13+ tests (~85–90s). Fix both and the suite drops to roughly 110–120s
with no change to async/sync structure. Async conversion is worth <15s.

## Method

- Checkout: `origin/main` `5d98a50`, 4 cores, own DB
  `spacetraders_test_speed_audit` on localhost:5579, `PORT=4093`.
- `mix test --slowest-modules 40 --slowest 30 --seed 0` → 1,253 tests, 0
  failures, `Finished in 269.9 seconds`, 272s wall.
- Caveat: `--slowest` implies `--trace`, which forces `max_cases: 1`. Async
  files therefore also ran serially in this run, so the 30s async / 240s sync
  split here is not comparable with #591's baseline. Per-module times are valid.
- Each non-test gate leg was timed as a separate `mix` invocation (adds ~0.6s
  VM start each; inside `mix verify` they share one VM).
- One experiment, reverted, never committed: Req `retry_delay: 0` through test
  config (see rank 2).
- CI timings: `gh run view 37372657674` (product-verification job).

## Where the time goes

Top modules (ms, serial trace run). Sync = `async: false`.

| Module | ms | Sync | Dominant cost |
|---|---:|---|---|
| RecordedShipFixtureOrderTest | 72,408 | yes | `System.cmd("mix", ["run", …])` re-runs 3 files ×2 orders ×2 iterations |
| RecordedFamilyInterruptionTest | 28,824 | yes | Sandbox `:auto`, shared `Req.Test`, real commits |
| ShipExecutionDurabilityTest | 27,777 | yes | one test 26.9s: repeated GET transport errors → Req backoff |
| FleetAcquisitionTest | 14,531 | yes | two tests ~6.7s each: Req backoff |
| FleetExecutionTest | 13,717 | yes | two tests ~6.6s each: Req backoff |
| API.ErrorTest | 13,604 | yes | 5xx + transport-error tests ~6.5–6.9s each: Req backoff |
| ListingTest | 13,360 | yes | one test: "~13s of 503 stubs" (file comment) |
| IntelligenceAcquisitionTest | 11,351 | yes | many ~1.0–2.1s tests (likely 1s first retry) |
| RecordedShipRuntimeTest | 11,337 | yes | RuntimeAuthority + Sandbox `:auto` |
| OwnedIntentRecoveryTest | 8,342 | yes | ~1.0s plateau tests |
| TransferRecoveryTest | 7,712 | yes | one 6.6s test: Req backoff |
| FleetStrategyTest | 6,844 | yes | one 6.5s test: Req backoff |

The top 40 modules are 97.3% of the time; the other ~50 modules together are
~7s.

### Rank-1 cost: the fixture-order test

`test/spacetraders/recorded_ship_fixture_order_test.exs` spawns
`mix run test/diagnostics/recorded_ship_fixture_order.exs`. That script runs
`recorded_ship_runtime`, `evidence_scheduling` and `resource_acquisition` in
two orders, twice: 12 ExUnit runs (about 4×12s + 4×2.4s + 4×0.5s), plus 12.6s
of child VM load. All three files already run in the main suite. It then
`IO.puts(output)`s the child transcript, which is ~1,090 lines of the 3,055-line
trace log. That is likely most of #591's 1,511-line success output.

### Rank-2 cost: real retry backoff

`SpaceTraders.API.retry/5` (`lib/spacetraders/api.ex` ~L716–742) returns
`true` for GET 5xx and `Req.TransportError`, so Req uses its default delays,
1s + 2s + 4s ≈ 7s per fully retried GET. `config_req_options/0` forwards only
`:plug`, so tests cannot shorten this today.

Experiment (code reverted): forward `:retry_delay` and set `retry_delay: 0` in
`config/test.exs`. Run on 11 affected files:

| Module | before ms | after ms |
|---|---:|---:|
| API.ErrorTest | 13,604 | 230 |
| ListingTest | 13,360 | 21 |
| FleetExecutionTest | 13,717 | 2,293 |

The blanket version is not safe as-is. It failed `429 Retry-After backoff … is
retried and the retry succeeds` (ErrorTest), and FleetAcquisitionTest hung
until a 400s timeout. Some tests depend on retry timing, so the fix has to keep
the 429/Retry-After path and treat the hang as a real finding. Summing the
~6.5s tests in the top-30 list (ErrorTest 2, Listing 2, FleetAcq 2, FleetExec
2, Transfer 1, Strategy 1, ShipExec ~4) gives ~85–90s. The ~1.0s plateau tests
are probably one 1s retry each, which would add more.

### Why files are `async: false` (34 of 92 `_test.exs` files)

| Shared global state | Files |
|---|---|
| App-wide clock: `Application.put_env(:spacetraders, :clock, TestClock)`; `TestClock` is a named Agent | clock, evidence_scheduling, fleet_acquisition, fleet_refit, owned_intent_recovery, resource_acquisition, transfer_recovery, recorded_ship_runtime |
| RuntimeAuthority config/singleton, direct Postgrex connection | runtime_authority, recorded_ship_runtime, operator_live/mint |
| Sandbox `:auto`/`unboxed_run`, real commits, shared `Req.Test` | ship_execution_durability, recorded_family_interruption, intent_transaction, gameplay_mutation, fleet_refit, owned_intent_recovery |
| App singletons (EmergencyStopAdmission ETS, CapacityGovernor, ShipSupervisor, Registry) | fleet_strategy, resource_recovery, api/error, agent, ship_server |
| Other app env (GrafanaLink) | grafana_link |
| No marker found (likely habit or indirect singleton use) | contracts, evidence_retirement, fleet_intents, fleet_read, fleet_generation, intelligence_acquisition, manual_intervention, listing, mission_control_*, strategy_live, recorded_dispatch_emergency_stop |

`DataCase.setup_sandbox/1` uses `shared: not tags[:async]`, so every sync
DataCase file also runs in shared sandbox mode.

## Other gate legs (not worth optimising)

| Leg | wall |
|---|---:|
| `compile --warnings-as-errors` cold, incl. deps | 61.4s |
| same, incremental after one-file edit / no-op | 9.1s / 0.7s |
| `format --check-formatted` | 1.2s |
| `gen.models --check` / `gen.operations --check` | 0.8s / 0.9s |
| `verify.boundary` | 1.0s |
| `verify.boot` | 1.2s |
| `Mix.Tasks.VerifyTest` nested `fixture.failing` child `mix` | 1.2s (in suite) |
| `Verify.BoundaryTest` | 1.25s (in suite) |

Excluding the suite, the local gate costs <5s warm. The `verify:
fixture.failing` self-test is cheap (`run_checks/2` with a stub, plus one 1.2s
child project with `+S 2:2`). Keep it.

CI product job (run 37372657674): 5m00s total. Container init 22s; bootstrap +
ecto prep 52s with **no `actions/cache`** for toolchain, deps or `_build`;
`scripts/verify` 3m37s; integration shell checks 3s.

## Ranked speedups

| # | Change | Est. saving (suite/gate wall) | Effort | Risk |
|---|---|---|---|---|
| 1 | Take `RecordedShipFixtureOrderTest` out of the gate: move it under `test/diagnostics` like `runtime_qualification.exs`, or cut to 1 iteration and drop `IO.puts(output)` | **~72s** (1 iteration: ~30s) and ~1,000 output lines | S (≤1h) | Loses an ordering guard that already passes. Run it as a diagnostic when teardown changes |
| 2 | Test-only short retry backoff: forward a `retry_delay` override for non-429 retries; keep Retry-After; fix the 429 test and the FleetAcquisition hang | **~85–90s**, likely more from ~1s plateau tests | M (2–4h incl. hang diagnosis) | Tests that assert backoff behaviour need an explicit opt-in to real delays |
| 3 | CI: `actions/cache` for `~/.local/opt/spacetraders-toolchain`, deps, `_build` keyed on `.tool-versions` + `mix.lock` | ~40s of the 52s prep step per job | S (≤1h) | Stale-cache bugs; key carefully |
| 4 | Partition: `mix test --partitions 2` with one DB per partition (`DATABASE_URL` per partition, not `MIX_TEST_PARTITION` naming per testing.md), or a 2-job CI matrix (each job already gets its own Postgres service) | After 1+2: ~110s → ~60s per partition (largest module 28.8s) | M (½–1 day; `mix verify` composition + local DB provisioning) | Partitions must never share a DB: RuntimeAuthority's direct connection and `:auto` sandbox commits collide. In CI each job re-pays prep unless #3 lands |
| 5 | Process-scoped Clock: resolve `TestClock` via `$callers`/NimbleOwnership like `Req.Test`, not `Application.put_env` | <10s; 8 files could become async, but their cost is durability, not clock | M | Runtime processes started outside the test need explicit allowances |
| 6 | Flip "no marker" files to `async: true` | <3s (each is ≤0.5s) | S | Indirect singleton use (EmergencyStopAdmission, CapacityGovernor) can flake. Low value |

Projected: 1+2 → suite ~110–120s, local gate ~120s (from 279s). Adding 3 → CI
~2m40s. Adding 4 → local gate ~65s, CI ~2m.

## Not answered

- What `IntelligenceAcquisition`, `ManualIntervention` and `OwnedIntentRecovery`
  spend their ~1.0s/test on. Probably one 1s Req retry each; unconfirmed.
- Why FleetAcquisitionTest hangs with zero retry delay. Investigate before
  rank 2 lands.
- Parallel (non-trace) per-module timing. The `--slowest` run is serial by
  construction.
