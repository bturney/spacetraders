# Recorded resource recovery — #572

Source main: `f36a20781c99f8849e75debac11355d61c0a8b4d`; prerequisite integration:
`17b28af5a518c0c5e4ea9f89152a1271dce71372` (#566). This receipt accompanies its
implementation commit on `opencode/kimaki-spec-502-572`.

## Current-main inventory and adoption

| Recorded operation | Existing selection / adoption |
| --- | --- |
| `extract-resources` | Acquire Resources selects ordinary extraction; now `Intents.execute_action/4` |
| `extract-resources-with-survey` | Same selection with an eligible Survey; same extraction continuation |
| `siphon-resources` | Acquire Resources selects siphoning; same lifecycle and resource judgment |
| `create-survey` | Acquire Resources composes its Survey prerequisite; same response continuation preserves returned Survey and cooldown |
| `ship-refine` | Acquire Resources selects refinement; exact 100 ore consumed / 10 requested product and total Cargo delta remain required |
| `jettison` | Existing recorded adapter; shared execution and recovery now recognize its selected Cargo decrement, with complete pre-action Cargo evidence required |

Current main has no Fleet planning/selection path for jettison. This adoption
supports the already recorded adapter at the selected-action seam; it adds no
jettison planner, root Intent type, intervention command, or resource capability.
Old selections lacking sufficient Cargo-before facts stay unresolved rather than
inventing a historical decrement.

## Consolidation and preserved ownership

Resource capability code supplies its selected outcome to the #566 lifecycle.
Deleted its preparation/dispatch/error continuation, redundant navigation
prerequisite progression, family ledger-state switch and separate recovery
timestamp/envelope assembly. Prepared boot dispatch, live dispatch and admitted
absence retry use `send_selected_action/3` / `continue_selected_response/5`.
Recovery conclusions use the existing `reconcile_accepted_attempt/4` and exact
`Evidence.recovery_proof/4`.

Cargo/yield consistency, refinement requirements, Survey eligibility, prerequisite
selection, cooldown waits and post-dispatch cooldown attribution remain Ship
Execution judgments. Re-entry after the accepted verdict commits can finish the
same selected outcome without a second verdict or send. MutationAttempts still
owns verdicts, retry consumption and retirement. No schema or independent
authority was added; independently committed preparation, marker, final admission
and transport implementation is unchanged.

Evidence's existing source validator now requires exact retained sources for all
six resource operations, even for direct ledger attempts without selection
metadata. Its Generation, scope, facts, fingerprint, freshness and original-time
validation remains the #566 implementation. No source-derived coverage extension
is needed: all six require the acting Ship's retained authoritative state.

Unchanged Cargo alone remains insufficient to infer resource absence. A lost
Survey response can prove the action through its post-dispatch cooldown but cannot
reconstruct the missing Survey signature. Existing conservative unknown handling
is preserved; durable owner-proven absence can consume its one authorized retry,
or retire it under Emergency Stop, through the shared lifecycle.

## Verification

Public seams: root Intents execution/re-entry, Evidence binding/proof assembly,
MutationAttempts and the game HTTP boundary. New resource cases cover the exact
original source after identical replacement, retention failure, unchanged Cargo,
prepared response continuation, outcome-commit re-entry, one-retry consumption,
Emergency Stop retirement and all six direct-ledger source requirements.
Existing resource capability tests remain intact. The unchanged runtime and
durability suites retain their separate PostgreSQL-observer commit/authority,
interruption, concurrent retry/admission and unrelated-Ship proofs.

All commands source `scripts/_toolchain.sh`, with
`MIX_BUILD_PATH=/tmp/opencode/572-build`,
`DATABASE_URL=postgres://postgres:postgres@localhost:5572/spacetraders_572_test`
and `PORT=4572`. Private PostgreSQL 17 container: `spec-502-572-postgres`.
Complete logs are retained under `/tmp/opencode/`.

| Stage / command | Actual result | Log |
| --- | --- | --- |
| Exact-source tracer | Red: 1 test, 1 failure (source identity omitted); green: 1 test, 0 failures | `572-exact-red.log`, `572-exact-green.log` |
| Six-operation ledger inventory | Red: 7 tests, 6 failures (unretained conclusions accepted); green: 7 tests, 0 failures | `572-inventory-red.log`, `572-inventory-green.log` |
| Prepared resource response continuation | Red: 11 tests, 4 failures (parallel boot protocol acquired another read); green plus existing resource/owned recovery: 53 tests, 0 failures | `572-prepared-behavior-red.log`, `572-prepared-green.log` |
| Accepted-outcome re-entry and jettison | Red: 17 tests, 6 failures; green plus existing resource/owned recovery: 59 tests, 0 failures | `572-outcome-reentry-red.log`, `572-outcome-reentry-green.log` |
| Resource, capability, owned recovery, runtime, independent durability, adapters and ledger: `mix test ... --seed 0 --trace` | Exit 0; 148 tests, 0 failures | `572-targeted-authoritative.log` |
| Typed rejection preservation | Exit 0; 22 resource tests, 0 failures | `572-rejection-red.log` (additional regression passed immediately) |
| `scripts/verify` | Exit 0; 839 tests, 0 failures; generated drift, transport boundary and HTTP 200 boot pass | `572-canonical.log` (before the additional rejection regression) |
| Intermediate `scripts/verify` | Exit 0; 840 tests, 0 failures; 280.3 seconds ExUnit; generated drift, transport boundary and HTTP 200 boot pass | `572-canonical-final.log` (`COMMAND_EXIT=0`) |
| Legacy jettison attribution | Red: 23 tests, 1 failure (markerless historical decrement accepted); green: 23 tests, 0 failures | `572-legacy-jettison-red.log`, `572-legacy-jettison-green.log` |
| Final resource-only `scripts/verify` | **Exit 0; 841 tests, 0 failures; 201.4 seconds ExUnit; generated drift, transport boundary and HTTP 200 boot pass** | `572-canonical-authoritative.log` (`COMMAND_EXIT=0`) |
| Post-integration targeted command (same seven files, `--seed 0 --trace`) | **Exit 0; 203 tests, 0 failures** | `572-integration-targeted.log` (`COMMAND_EXIT=0`) |
| Post-integration `scripts/verify` | **Exit 0; 920 tests, 0 failures; generated drift, transport boundary and HTTP 200 boot pass** | `572-integration-canonical.log` (`COMMAND_EXIT=0`) |

The initial prepared test fixture incorrectly had 100 Cargo units in capacity 40;
`572-prepared-red.log` records that fixture failure. The corrected independent
behavioral red is `572-prepared-behavior-red.log`. Initial Stop coverage edited a
Strategy row directly instead of invoking the public admission-owning Stop;
`572-complete-targeted.log` retains that fixture failure. The corrected case uses
`FleetStrategy.engage_emergency_stop/1` and cleans up its own admission cache entry.

## Current integration merge

Resource implementation commit: `f3be4eb`. Merged integration
`aa3c272b74dbd9c18966b3e8a50e1b4be3c43118` into the resource branch before handoff.
Bounded conflicts were the adopted-action predicate, response-continuation clauses,
typed rejection handling and required-source allowlist. Resolution adopts
integration's `unified_action?/1`, adds the resource kinds there, retains all other
family continuations and unions every existing exact-source guard. Integration's
`reconcile_selected_attempt/2` now also supplies resource accepted reconciliation.
Post-integration verification above ran against this resolved tree.

## Limits

This is the #572 resource-family adoption within the bounded Gate 1 increment.
Combined-family contraction/qualification belongs to #575/#576. Existing
jettison Fleet reachability, unresolved resource attribution, spending-exposure
qualification and parent #502 Gates 2–5 (including the approved multi-day live
trial) are not certified by these tests.
