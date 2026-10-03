# Testing

Read before running or debugging the ExUnit suite, especially when a failure
looks environment-related.

## The gate

`scripts/verify` (== `mix verify`) is the canonical gate. Its checks are
`Mix.Tasks.Verify.required_checks/0` in `lib/mix/tasks/verify.ex`; read it
rather than trusting a list elsewhere.

The gate stops at the first failing check, so a red run means the named check
is the one to fix. Its exit status is the verdict: a failure is never recovered
from, and no check's output is parsed to decide the result.

The gate prints a lot. Inline tool output can truncate mid-run and leave the
result unknown: redirect it to a file and read the tail, or rely on the
command's exit status.

## Expected noise

Postgrex `admin_shutdown` disconnect lines during a full run are sandbox
teardown noise, not failures. `config/test.exs` sets `logger: :error`, and the
suite uses the Ecto `Sandbox` pool; treat a clean exit as the signal.

## Database

`mix test` assumes a prepared, migrated PostgreSQL database. The test alias
never creates, drops, or migrates it; `DataCase` transactions provide ordinary
test isolation. For a direct targeted run, prepare the database once with
`MIX_ENV=test mix ecto.create` and `MIX_ENV=test mix ecto.migrate`. `scripts/verify`
performs those provisioning steps before running the canonical gate.

The default test URL is the stable
`postgres://postgres:postgres@localhost/spacetraders_test`; set `DATABASE_URL`
to select another prepared database. Worktree setup allocates a task-named URL,
and `scripts/teardown` drops that task's database as it releases the task's port.
Do not use `MIX_TEST_PARTITION` to select databases; provision and select each
database explicitly with `DATABASE_URL`.

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
