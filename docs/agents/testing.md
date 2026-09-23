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

The test database is partitioned per run: `MIX_TEST_PARTITION`, else
`System.pid()` (`config/test.exs`). `SpaceTraders.RuntimeAuthority` opens a
direct connection to the base database and can terminate backends, which
produces full-suite-only failures and garbled constraint errors.

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