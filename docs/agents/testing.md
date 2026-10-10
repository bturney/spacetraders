# Testing

Read before running or debugging the ExUnit suite, especially when a failure
looks environment-related.

## The gate

`scripts/verify` (== `mix verify`) is the canonical gate. Its checks are
`Mix.Tasks.Verify.required_checks/1` in `lib/mix/tasks/verify.ex`; read it
rather than trusting a list elsewhere.

CI prepares the pinned toolchain, dependencies, and migrated test database,
then invokes `scripts/verify` directly. Local runs use the same gate after
preparing those prerequisites; no runner identity variables are required.
Local gate edits working tree: `mix format` fixes files. CI (`CI` set) runs
`--check-formatted`.

The gate stops at the first failing check, so a red run means the named check
is the one to fix. Its exit status is the verdict: a failure is never recovered
from, and no check's output is parsed to decide the result.

Output contract (PASS/FAIL footer, rerun command, `--max-failures 5`) lives in
the `Mix.Tasks.Verify` moduledoc. Red run: fix the check named in
`verify: FAIL at <check>`, rerun the command it prints.

## Release and deployment verification

Outside the product gate, CI runs these under the separate
`release-deployment-verification` job. They are operational checks that protect
merges:

```sh
test/integration/postgres_compose_test.sh
test/integration/release_boot_test.sh
test/integration/migration_repair_test.sh
```

They require Docker Compose, the pinned toolchain and dependencies, and a
running PostgreSQL test database. `release_boot_test.sh` builds and boots the
production release; `migration_repair_test.sh` creates and removes its own
temporary database.

## Stray output

`capture_log: true` is suite-wide. The gate's test check fails a passing run
that prints anything beyond ExUnit formatter output (after the `Running
ExUnit` line), naming the first stray line. No opt-out tag. A test that prints
on purpose asserts with `capture_io`/`capture_log`. Never `IO.inspect`/`IO.puts`
in tests; put diagnostics in the assertion or `flunk` message.

## Postgrex disconnects

A passing run prints no Postgrex disconnect lines; one in output is a real
problem. A process killed while it holds a sandbox connection makes the
ownership proxy disconnect it and log an error (#398). So:

- Runtime processes a test starts: `start_supervised!(Quiesced.child_spec(child))`;
  teardown waits out any open checkout before stopping them.
  Ship servers: `Quiesced.stop_ship/1` and `Quiesced.stop_all_ships/0`, never `ShipServer.stop/1`.
- Killing a sender mid-transaction on purpose: `RuntimeDeath.kill/2` asserts
  the disconnect instead of printing it.

## Database

One shared Postgres (`docker compose -f compose.dev.yaml up -d`, 127.0.0.1:5432)
serves all checkouts. `DataCase` transactions provide ordinary test isolation.
The `mix test` alias first seeds `deps/` and `_build/test` from the main checkout
when absent (`seed_from_main/1` in `mix.exs`; needs the main checkout built;
cold ~12s, warm ~2s), then runs `ecto.create` and `ecto.migrate` (quiet), so a
fresh checkout needs no setup. Seeding also runs `scripts/prune` (removes clean,
idle, merged, unlocked worktrees and orphan checkout databases; lists the rest;
`--dry-run` previews). Run it by hand any time; a prune failure never fails
`mix test`.

The database name derives from the checkout (`config/checkout_db.exs`): main
checkout `spacetraders_test`; a worktree `spacetraders_test_<dir>_<hash6>`. Set
`DATABASE_URL` to override. Do not use `MIX_TEST_PARTITION` to select databases.

`SpaceTraders.RuntimeAuthority` opens a direct connection to the base database
and can terminate backends, which produces full-suite-only failures and garbled
constraint errors.

When a test fails only in the full suite, compare against a clean
`origin/main` checkout before blaming the change — the failure may be
environment flakiness. Run one file directly to isolate a real regression.

## Regression workflow

Put each behavioral contract at its smallest supported seam and give each test
only the setup it needs. Use `DataCase` for transactional persistence tests;
tests of independent durability use synchronous ExUnit cases, real PostgreSQL
commits, and a separately checked-out observer. Stub the game boundary with
`Req.Test`; test env disables API rate limiting.

Current seam owners:

- first-operator AccountToken persistence:
  `test/spacetraders_web/controllers/operator_setup_controller_test.exs`
- authenticated Agent minting:
  `test/spacetraders_web/live/operator_live/mint_test.exs`
- API outcome telemetry and token redaction:
  `test/spacetraders/api/client_test.exs`
- Ship arrival retry/rearm behavior:
  `test/spacetraders/fleet/ship_server_test.exs`
- Server Reset and Fleet Strategy continuity:
  `test/spacetraders/fleet_generation_test.exs`
- Mission Control briefing and truthful unknown state:
  `test/spacetraders_web/live/mission_control_briefing_test.exs`
- first dispatch durability and ambiguous recovery:
  `test/spacetraders/ship_execution_durability_test.exs`
- recorded Ship recovery per family (exact Bindings, verdicts, one retry):
  `test/spacetraders/owned_intent_recovery_test.exs`,
  `test/spacetraders/transfer_recovery_test.exs`,
  `test/spacetraders/resource_recovery_test.exs`
- refuel and jump/antimatter credit authority through the root Intent lifecycle:
  `test/spacetraders/refuel_jump_spending_test.exs`
- recorded runtime interruption, authority races, and boot recovery:
  `test/spacetraders/recorded_ship_runtime_test.exs`
- per-family interruption phase matrix and authority loss (every recorded Ship
  family): `test/spacetraders/recorded_family_interruption_test.exs`
- recorded admission boundary and Ship operation coverage:
  `test/spacetraders/api/recorded_dispatch_test.exs`
- concurrent and restart-safe credit admission (Agent lock contention,
  Reservations, reconstructed exposure, quote aging across restart):
  `test/spacetraders/credit_spending_qualification_test.exs`
- credit calibration versions, realized-versus-quoted evidence, shortfall
  classification, and spending pause/release:
  `test/spacetraders/credit_calibration_test.exs`
- eager floor revalidation (below-floor balance read, revision activation):
  `test/spacetraders/credit_floor_watch_test.exs`
- root Intent Capacity Deferral (recovery-read 429, bounded governor-guided
  wakeup, restart, wake revalidation, mutation-response Evidence reuse, deferral
  metric): `test/spacetraders/capacity_deferral_test.exs`. Fleet capacity
  callers (`FleetCapacity.disposition/2`, used by `CapacityDeferral`) ask an
  isolated governor only through the explicit test seam
  `Application.put_env(:spacetraders, SpaceTraders.FleetCapacity, governor: name)`;
  restore it in `on_exit`. Production sets nothing.
- API Capacity Governor lifecycle (Retry-After bound, protected probe pacing,
  scoped vs Fleet-wide outage, abandoned callers, restart, diagnostics):
  `test/spacetraders/api/capacity_governor_test.exs`. The app-wide test
  governor probes with no backoff delay (`probe_base_ms: 0` in
  `config/test.exs`); isolated governors pass their own timing.

- whole-runtime composition across runtime restart, and Gate 1 spending and
  capacity authority through Strategy activation ("Gate 1 authority" describe):
  `test/diagnostics/runtime_qualification.exs` (diagnostic only)

- native Bandit outcome exporter ownership and coherent HTTP scrapes:
  `test/diagnostics/outcome_http.exs` (diagnostic only)

## Native outcome HTTP diagnostic

Run when changing native `/metrics` response ownership or HTTP scrape coherence:

```sh
mix test test/diagnostics/outcome_http.exs --seed 0 --trace
```

Done: HTTP 200 after committed domain observations; one publisher; coherent
bytes during held-open Fleet publication. The diagnostic owns its loopback
ephemeral listener and real-commit DB cleanup. Explicit run only: ordinary test
discovery and `scripts/verify` bind no port (ADR 0014). Socket-free seams remain
in `test/spacetraders_web/{fleet_outcome_metrics,outcome_metrics}_test.exs`.

## Runtime qualification

`test/diagnostics/runtime_qualification.exs` is a timing-sensitive, standalone
diagnostic, not merge verification. It asks whether fresh authenticated Strategy
activation composes the production runtime into a profitable distant trade
across a runtime restart and surfaces the result in Mission Control. Its clock,
API stub, PostgreSQL mode, authenticated connection, and teardown are local to
that diagnostic; it does not introduce a shared test lifecycle.

The `Gate 2A partial-coverage handoff` describe (#675) runs the same seam
against `test/support/runtime_fleet_game.ex`, a two-Ship (FRAME_FRIGATE hold 40,
FRAME_PROBE no hold/tank) located, fuel-consuming game with route depth 60 and
unobserved Marketplaces. Scenarios never publish, select or execute directly;
the production runtime does, including buy and sell against the stub: trade before
coverage completes, restart with Cargo in flight, source price move, unusable
retained evidence (stale, untraceable, invalidated, wrong-Generation, future),
Capacity Deferral, swapped event order, and bounded telemetry. Run one with
`--only describe:"Gate 2A partial-coverage handoff"`.

The `Gate 2B Revision change during coverage` describe (#685, #686) reproduces
production Portfolio 4039 / Intent 4077 on the same seam: the scout's navigate
succeeds, the Operator activates a new Revision through the Strategy LiveView
while it is in transit, the scout arrives and its next step is refused on
old-Portfolio authority. It asserts the stale Claim releases without a Safety
Fence, current-Revision coverage and a profitable trade follow, and one
resolved `structural_stall` Episode records the reconciliation. Deterministic
variants (unresolved action fence, inherited Cargo disposition, 500-tick stall
deduplication, busy/deferred/Shortfall negatives) live in
`test/spacetraders/market_domain_allocation_test.exs`.

Run it only when that whole-runtime composition is the subject:

```sh
mix test test/diagnostics/runtime_qualification.exs --seed 0 --trace
```

The file deliberately does not end in `_test.exs`, so ordinary `mix test` and
`scripts/verify` do not discover it. Keep seam-level assertions in their
deterministic owners: Observation Demand restart in
`test/spacetraders/evidence_scheduling_test.exs`, incomplete Market coverage
planning in `test/spacetraders/fleet_planning_test.exs`, and first/lost-response
Ship dispatch recovery in
`test/spacetraders/ship_execution_durability_test.exs`.

## Fleet Generation resets

Server Reset continuity lives in `test/spacetraders/fleet_generation_test.exs`:
transactional `DataCase`, public Fleet Generation and Fleet Strategy interfaces,
and `Req.Test` at the game HTTP boundary. Observe retention through Agent queries
and Generation history. Admission-cache cleanup requires synchronous execution.

## Evidence scheduling

Persisted Observation Demand scheduling lives in
`test/spacetraders/evidence_scheduling_test.exs`: `DataCase`, real PostgreSQL,
and locally supervised `TestClock` and `DemandScheduler`. Assert public Evidence
queries and due notifications. Restart proofs discard clock timers as well as the
scheduler; PostgreSQL alone retains the requirement. The case is synchronous
because clock configuration is application-wide; ExUnit supervision owns process
shutdown before sandbox cleanup.
