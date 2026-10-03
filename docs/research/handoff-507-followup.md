# Handoff: issue 507 recorded Ship execution qualification

Branch `feature/507-recorded-ship-qualification`, pushed. PR:
https://github.com/bturney/spacetraders/pull/558
Commits: `4ce4da3` (original increment), `9c27ef7` (PR feedback follow-up).
Base: `c97fc58d6c4e3986b80dbacfe4998cf395449811`.
Report: `docs/research/recorded-ship-qualification-507.md`.
Evidence: https://gist.github.com/bturney/d1416360b9b5a74ea07ab554ccfa068a

## Read this first

**The canonical gate is red at HEAD: 806 tests, 1 failure.** Log:
`/tmp/opencode/507-feedback-canonical.log`. Everything else passes. The failing
case is *not* a qualification regression — see "Known failure" below. Do not treat
CI green as the current state; rerun the gate after fixing it.

Operator PR feedback is addressed and reviewed. Parent #502 stays open. No
production deployment, migration, merge, or Emergency Stop operation was performed.

## Done and verified

- Ten interruption boundaries and twelve authority-loss cases through
  authenticated Strategy activation, production coordination and boot
  (`test/spacetraders/recorded_ship_runtime_test.exs`, 29 tests).
- Three protocol violations found and fixed: authority loss after send-marker
  commit reached transport; a stale callback restored a changed selection;
  a proven-absence retry under Emergency Stop blocked resume preparation.
- Final transport admission is now explicit: **successful completion of
  `RecordedDispatch.authorize_transport/1`'s transaction.** Revocation winning
  first suppresses transport; authorization winning first admits one
  non-recallable request. Four both-order race cases plus an in-transaction
  overlap proved through the observer's `pg_blocking_pids`.
- Semantic phase telemetry replaced Ecto SQL/parameter parsing. Pre-commit:
  `preparation_written`, `marker_written`, `outcome_written`. Post-commit:
  `prepared`, `marker_committed`, `transport_authorized`, `outcome_committed`.
- RateLimiter takes a local monotonic clock (`now/0`, `sleep/1`); its public
  `acquire/1` tests assert grants at 500/1000/1500ms instead of wall-clock elapsed
  time.
- Fixture lifecycle proved by running the real qualification,
  EvidenceScheduling and ResourceAcquisition files consecutively in one child
  VM, both orders, twice (164 child cases), plus config/Sandbox/Req/process/
  admission-state probes. This found a real leak against the original PR:
  teardown changed absent `:clock` config into `{:ok, nil}`. Fixed.
- Concurrent retry/admission and independently claimed Ship continuation
  proofs in `test/spacetraders/ship_execution_durability_test.exs`.
- Rollout/compatibility readiness report, including the forward-only cutover the
  existing `scripts/deploy-host` already enforces.

## Known failure — investigate first

```
1) test active Strategy discovers a remote extraction Waypoint for a new Agent
   (SpaceTraders.ResourceAcquisitionTest)  test/spacetraders/resource_acquisition_test.exs:115
   expected {:ok, %Intent{status: "waiting", target_waypoint: "X1-UX81-A2"}}
   actual   {:error, :resource_acquisition_unavailable}
```

It appears only on the **second** run of that file inside one child VM, in
`test/diagnostics/recorded_ship_fixture_order.exs`. Standalone, in the first
ordered run, and in `/tmp/opencode/507-stop-repro-1.log` the same file passes.
`FleetResources.reconcile/5` collapses every failing guard into that one atom, so
the receipt does not name the cause.

Prime suspect: a seeded remainder a same-VM repeat run does not clear —
`Evidence.read/3` coalesces concurrent identical reads through the globally named
`SpaceTraders.Evidence.ReadCoordinator`; `DataCase` only rolls back the
transaction. Also check retained Observation/ObservationDemand rows and
CapacityGovernor state. Cheapest next step: instrument the `with` in
`lib/spacetraders/fleet_resources.ex` to log the failing guard, then run
`mix test test/spacetraders/recorded_ship_fixture_order_test.exs --seed 0 --trace`
until it fails.

Two earlier CI attempts also failed once each in unchanged code
(ResourceAcquisition at seed 522169; DemandScheduler Sandbox ownership at seed
392303). Clean `c97fc58` passed its 774-test suite at both seeds. Those causes
are unestablished and **not** claimed to be the same issue.

## Commands

```sh
source scripts/_toolchain.sh
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate   # once
mix test test/spacetraders/recorded_ship_runtime_test.exs --seed 0 --trace
mix test test/spacetraders/recorded_ship_fixture_order_test.exs --seed 0 --trace
scripts/verify                                                    # currently red
```

Test DB: `postgres://postgres:postgres@localhost/spacetraders_test`. No separate
Elixir typechecker; `MIX_ENV=test mix compile --warnings-as-errors` is the gate.

## Explicitly out of scope

Not certified: independent Fleet Allocation, net profitable trading, full
C02/C05/C06, Gate 1, reset-to-reset autonomy. Trading evidence is mixed — the
opt-in diagnostic shows +800 cash credits while consuming inventory fuel, and
archived negative runs are retained deliberately. Verification-tool changes
belong to #400.

## Next boundary

Fix the open failure, rerun `scripts/verify`, then update the report's receipts.
Merge and deployment still need explicit Operator authorization.