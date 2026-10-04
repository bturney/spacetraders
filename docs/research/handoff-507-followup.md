# Handoff: issue 507 recorded Ship execution qualification

Branch `feature/507-recorded-ship-qualification`, pushed. PR:
https://github.com/bturney/spacetraders/pull/558
Key commits: `4ce4da3` (original increment), `9c27ef7` (PR feedback follow-up),
`cfdd32f` (deterministic ResourceAcquisition reproduction), `a902732`
(causal-time fix), `5728036` (DemandScheduler downtime-test synchronization),
and `30da783` (global CapacityGovernor assertion isolation).
Base: `c97fc58d6c4e3986b80dbacfe4998cf395449811`.
Report: `docs/research/recorded-ship-qualification-507.md`.
Evidence: https://gist.github.com/bturney/d1416360b9b5a74ea07ab554ccfa068a

## Read this first

**The handoff failures have been reproduced or isolated to concrete races and
corrected.** Executable revision
`30da78395475dce24e584603c27d582345039235` passed the canonical GitHub Actions
product gate with **806 tests, 0 failures** (seed 888514), the same-VM lifecycle
proof in both orders repeated twice, and release-deployment verification. See
"Resolved handoff failure" and "Additional suite races" below for the red/green
proof.

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

## Resolved handoff failure

The repeated `ResourceAcquisitionTest` failure was a causal-time race, not a
retained ReadCoordinator, CapacityGovernor, Sandbox, or ShipServer state leak.

Failure-only diagnostics on GitHub Actions run 37157861527 showed that the test
successfully completed `GET /v2/my/ships`, Agent overview, local Waypoint read,
and paginated Waypoint discovery, then failed before any Ship-specific read or
mutation. At that point CapacityGovernor had available admission, the
ReadCoordinator pending map was empty, and no ShipServer was needed to explain
the failure.

`FleetResources.reconcile/5` captured its planning `as_of` before discovery.
New Waypoint evidence is persisted with the application clock, while
`FleetPlanning.plan_resources/3` correctly rejects evidence whose
`observed_at` is later than the decision `as_of`. Crossing the next second
during discovery could therefore make the newly discovered Asteroid ineligible,
yielding the generic `{:error, :resource_acquisition_unavailable}`.

Commit `cfdd32f214c6d549a3a482c728cc5f21f6fefde4` made this deterministic by
advancing `TestClock` five seconds during the paginated Waypoint response.
GitHub Actions run 37158317387 failed 806 tests with two instances of that same
case (ordered child proof plus outer suite). Commit
`a902732d0c71c35b3632d8bbede142dd3c2c972b` then made FleetResources use the
application `Clock` consistently and capture the planning/allocation `as_of`
after discovery. Run 37158344191 passed 806 tests, 0 failures; the ordered
lifecycle proof passed both orders twice and release-deployment verification
also passed.

The planner invariant was not relaxed: evidence still may not post-date the
decision snapshot. The caller now supplies the correct post-discovery snapshot.

## Additional suite races

Continuing the handoff reproduced the historical EvidenceScheduling
Sandbox-ownership failure. The deadline-downtime test stopped DemandScheduler
immediately after receiving its due broadcast, but `wake_due/1` still performs
its final durable rearm query after broadcasting. Killing the scheduler in that
window could disconnect the shared Sandbox owner; the replacement scheduler then
failed in `:manual` mode. Commit `5728036` waits for the scheduler callback to
finish with `:sys.get_state/1` before simulating downtime. The repeated
same-VM lifecycle diagnostic subsequently passed every EvidenceScheduling and
ResourceAcquisition run in both orders twice.

The next gate exposed a separate test-isolation issue in `API.ErrorTest`. It ran
asynchronously while asserting the application-wide CapacityGovernor rejection
window, which another concurrent successful API request may clear. Commit
`30da783` makes that module synchronous because it intentionally observes global
governor state. GitHub Actions run 37164225616 retained the red assertion; run
37164549577 passed the complete 806-test product gate and release verification on
the first run of the corrected head.

## Commands

```sh
source scripts/_toolchain.sh
MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate   # once
mix test test/spacetraders/recorded_ship_runtime_test.exs --seed 0 --trace
mix test test/spacetraders/recorded_ship_fixture_order_test.exs --seed 0 --trace
scripts/verify                                                    # green at 30da783
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

The handoff failures are fixed and their red/green evidence is recorded in the
qualification report. Current executable head `30da783` has a clean canonical
product and release verification receipt. Merge and deployment still need
explicit Operator authorization. Parent #502 remains open for the broader gates
listed above.