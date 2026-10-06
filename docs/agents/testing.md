# Testing

Read before running or debugging the ExUnit suite, especially when a failure
looks environment-related.

## The gate

`scripts/verify` (== `mix verify`) is the canonical gate. Its checks are
`Mix.Tasks.Verify.required_checks/1` in `lib/mix/tasks/verify.ex`; read it
rather than trusting a list elsewhere.

CI prepares the pinned toolchain, dependencies, and migrated test database,
then invokes `scripts/verify` directly. Local runs use the same gate after
preparing those prerequisites; no runner identity variables are required. The
one difference: locally `mix format` fixes files (the gate edits your working
tree and says so), while CI (`CI` env var set) runs `--check-formatted`.

The gate stops at the first failing check, so a red run means the named check
is the one to fix. Its exit status is the verdict: a failure is never recovered
from, and no check's output is parsed to decide the result.

Output is short: `verify: <check> ok <s>` per check, the ExUnit summary, then
`verify: PASS 7/7 <s>`. On failure the failing check's native output is shown
(tests stop at `--max-failures 5`), then `verify: FAIL at <check>` and the
rerun command. Still rely on the exit status for the verdict.

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

## Expected noise

Postgrex `admin_shutdown` disconnect lines during a full run are sandbox
teardown noise, not failures. `config/test.exs` sets `logger: :error`, and the
suite uses the Ecto `Sandbox` pool; treat a clean exit as the signal.

## Database

`mix test` assumes a prepared, migrated PostgreSQL database. The test alias and
`scripts/verify` never create, drop, or migrate it; `DataCase` transactions
provide ordinary test isolation. Prepare the database once with
`MIX_ENV=test mix ecto.create` and `MIX_ENV=test mix ecto.migrate` before a
targeted test run or the canonical gate.

The default test URL is the stable
`postgres://postgres:postgres@localhost/spacetraders_test`; set `DATABASE_URL`
to select another prepared database. Do not use `MIX_TEST_PARTITION` to select
databases; provision and select each database explicitly with `DATABASE_URL`.

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
- recorded runtime interruption, authority races, and boot recovery:
  `test/spacetraders/recorded_ship_runtime_test.exs`
- per-family interruption phase matrix and authority loss (every recorded Ship
  family): `test/spacetraders/recorded_family_interruption_test.exs`
- recorded admission boundary and Ship operation coverage:
  `test/spacetraders/api/recorded_dispatch_test.exs`

- whole-runtime composition across runtime restart:
  `test/diagnostics/runtime_qualification.exs` (diagnostic only)

## Runtime qualification

`test/diagnostics/runtime_qualification.exs` is a timing-sensitive, standalone
diagnostic, not merge verification. It asks whether fresh authenticated Strategy
activation composes the production runtime into a profitable distant trade
across a runtime restart and surfaces the result in Mission Control. Its clock,
API stub, PostgreSQL mode, authenticated connection, and teardown are local to
that diagnostic; it does not introduce a shared test lifecycle.

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
