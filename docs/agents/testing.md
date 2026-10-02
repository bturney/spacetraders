# Testing

Read before running or debugging the ExUnit suite, especially when a failure
looks environment-related.

## The gate

`scripts/verify` (== `mix verify`) is the canonical gate. Its steps are the
`verify` alias in `mix.exs`; read it rather than trusting a list elsewhere.

The gate prints a lot. Inline tool output can truncate mid-run and leave the
result unknown: redirect it to a file and read the tail, or rely on the
command's exit status.

## Expected noise

Postgrex `admin_shutdown` disconnect lines during a full run are sandbox
teardown noise, not failures. `config/test.exs` sets `logger: :error`, and the
suite uses the Ecto `Sandbox` pool; treat a clean exit as the signal.

## Database

Worktree setup names a test database after the task and writes the resulting
`DATABASE_URL` into the task environment, so two concurrent gates in separate
worktrees drop and recreate different databases. `scripts/teardown` drops the
task's database, the same way it releases the task's port.

A bare `scripts/verify` in an ordinary checkout uses the single database name
it has always used. Only when no `DATABASE_URL` is set at all does the config
fall back to a per-run partition — `MIX_TEST_PARTITION`, else `System.pid()`.
That fallback is per *run*, and the `test` alias drops the database at the start
of a run and never at the end, so a bare `mix test` with no `DATABASE_URL` leaves
its partitioned database behind permanently. Set `DATABASE_URL`, or work in a
worktree.

`SpaceTraders.RuntimeAuthority` opens a direct connection to the base database
and can terminate backends, which produces full-suite-only failures and garbled
constraint errors.

When a test fails only in the full suite, compare against a clean
`origin/main` checkout before blaming the change — the failure may be
environment flakiness. Run one file directly to isolate a real regression.

## Scenario tests

`SpaceTraders.ScenarioCase` drives authenticated Phoenix interfaces with
controlled API responses, a shared fake clock, and process restarts. Its
teardown calls `ShipServer.stop_all()` (`test/support/scenario_case.ex`), after
which the shared sandbox owner is no longer usable. Do not build a fix on the
assumption that the owner survives teardown.

In test env the API transport is stubbed with `Req.Test` and the rate limiter is
disabled (`config/test.exs`).

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
