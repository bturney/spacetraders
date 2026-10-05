# Scan/chart recovery — #571

Base: fresh `origin/main` at `f36a20781c99f8849e75debac11355d61c0a8b4d`,
with #566 integrated at `17b28af` on `opencode/kimaki-spec-502-integration`.
This receipt belongs to its containing commit on `opencode/kimaki-spec-502-571`.

## Adopted interfaces and deletion

Scan Waypoints and Chart now select through `Fleet.Intents.execute_action/4`.
Live dispatch, prepared boot dispatch, and an already-authorized absence retry
enter the existing `send_selected_action/3` / `continue_selected_response/5`
progression. Responses retain their selected Intent/attempt identity; the existing
locked transition rejects obsolete callbacks, including callbacks from an older
retry of the same selection. No admission transaction, transport adapter, ledger,
or independent durability boundary was replaced.

Deleted both capabilities' preparation/dispatch/continuation choreography and
their reconstructed observation envelopes, dependency assertions, latest-source
timestamp lookups, and family-local ledger-state branching. Selected work no
longer completes merely because unrelated Intelligence satisfies its requested
facts while its mutation remains unresolved.

The capability owner still judges a scan's post-dispatch cooldown and chart
provenance (matching Agent and post-dispatch, non-future submission time). Returned
Intelligence retention and requested-fact completion remain operation-specific.
A successful recorded scan can retire its selection after its cooldown expires;
missing returned Intelligence stays explicitly unavailable rather than causing a
blind replay. An incomplete chart callback retains its selection for recovery.

## Evidence and recovery authority

`Evidence.get_waypoint/4` accepts `bind: true` and returns the same
`%Evidence.Binding{value: decoded_waypoint, observation: exact_source}` contract
introduced by #566. Failed retention returns an evidence gap. Bound concurrent
World reads coalesce the **retained binding**, not separate freshly timestamped
copies of one decoded response; their result-shaped key is separate from ordinary
decoded reads. Ordinary callers retain their existing result shape.

`Evidence.retained_waypoint_binding/2` restores an exact observation by identity
without a game request. `Evidence.recovery_proof/4` derives Chart coverage only
from a retained Waypoint response whose subject, System, Waypoint and chart facts
match. Ship cooldown coverage uses #566's retained Ship source. The original
observation ID, acquisition time, Generation and fingerprint travel into the
ledger proof; newer identical observations do not replace them.

MutationAttempts remains the sole durable verdict and retry authority. Its final
Evidence validator now requires retained sources for both operation IDs and
selected kinds, even for direct callers without selection metadata. Existing
locked dependency scope, 30-second freshness, post-dispatch time, non-future time,
Generation and source-integrity validation remain in force. Proof assembly makes
no hidden reads and adds no lifecycle persistence.

## Behavioral proof and verification

The approved seams are Evidence binding/assembly, root Intents execution/re-entry,
MutationAttempts, and the game HTTP boundary. New cases in
`owned_intent_recovery_test.exs` cover exact scan-source restart reuse after an
identical-fact replacement, exact Waypoint restoration, stripped-source rejection,
one binding for coalesced reads, equivalent live/prepared-boot scan continuation,
durably successful scan re-entry, incomplete chart callbacks, chart retention
failure despite satisfied Intelligence, and wrong-Agent/pre-dispatch/future/missing
chart provenance. Existing capability tests and the #507 independent PostgreSQL
observer, interruption, authority-loss and concurrent-retry suites remain intact.

All commands source `scripts/_toolchain.sh`. Private writable build:
`MIX_BUILD_PATH=/tmp/opencode/571-build`. Prepared isolated database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5571/spacetraders_571_test`.
Container: `spec-502-571-postgres`; boot `PORT=4571`.

| Command / proof | Actual result | Full log under `/tmp/opencode/` |
| --- | --- | --- |
| Scan exact-source tracer | Red: 1 selected failure, source ID absent; green: 1 selected pass | `571-scan-source-red.log`, `571-scan-source-green.log` |
| Waypoint binding/restart tracer | Red: 1 selected failure, decoded-only result; green: 1 selected pass | `571-chart-binding-red.log`, `571-chart-binding-green.log` |
| Prepared scan continuation, expired successful scan, incomplete chart callback | Each red: 1 selected failure; final targeted run passes all | `571-progression-red.log`, `571-scan-committed-red.log`, `571-chart-incomplete-red.log` |
| Coalesced exact-source tracer | Red: exit 2, 1 selected failure, two retained IDs for one read; green: exit 0, 78 tests, 0 failures including owned recovery and Intelligence acquisition | `571-coalesced-source-red-final.log`, `571-coalesced-source-green.log` |
| Owned recovery + Intelligence acquisition + recorded runtime + Ship durability, `mix test ... --seed 0 --trace` | Exit 0; 118 tests, 0 failures (before final coalesced-source case) | `571-targeted-final.log` |
| Final `scripts/verify` | **Exit 0; 829 tests, 0 failures; 229.4 seconds ExUnit.** Compile, format, generated models/inventory, gameplay boundary and boot `/health` 200 pass | `571-canonical-authoritative.log` (`COMMAND_EXIT=0`) |

Earlier diagnostics remain retained: `571-progression-green.log` (two exposed
fixture/continuation gaps), `571-targeted.log` (one completed-Intent ledger lookup
fixture error), `571-coalesced-source-red.log` (transport-start synchronization
timeout), and `571-canonical.log` (828 tests, exit 0 before the coalescing
correction). The final red uses explicit transport synchronization and observes
the distinct public source IDs; it does not depend on response timing luck.

## Qualification boundary

No known #571 acceptance gap remains. No new scan capability or Intelligence
owner was introduced. #575 still owns shared compatibility contraction; #576
owns combined-family qualification. This receipt does not qualify the separate
spending-authority exposure or parent #502 Gates 2–5 and approved live trial.
