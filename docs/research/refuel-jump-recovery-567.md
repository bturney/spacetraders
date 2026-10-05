# Refuel and jump recovery — #567

Base: `17b28af`, with #566 integrated on
`opencode/kimaki-spec-502-integration`. Ticket #567 was rechecked open, unassigned
and `ready-for-agent`, then claimed before implementation. This receipt belongs
to its containing commit on `opencode/kimaki-spec-502-567`.

## Implemented boundary

Refuel and jump now select through `Fleet.Intents.execute_action/4`. Live sends,
prepared boot recovery and proven-absent retries use the existing selected-action
send/response progression. Deleted family-specific preparation, dispatch and
response choreography; duplicate Ship-and-credit envelopes, timestamp lookups,
credit extraction from constructed envelopes, and the extra ledger/provenance
lookup of pre-refuel fuel.

The operation owner still judges fuel restoration, unchanged fuel, arrival and
unchanged jump-preflight credits. Route eligibility, reviewed Flight Mode,
Market availability, spending/preflight checks, fuel-stop routing and gameplay
rejection handling retain their meaning. Successful refueling still refreshes
Ship state before advancing, now for both live and retry/boot continuation.

`RecordedAction` retains its independently committed preparation, send marker
and final admission. Transport remains outside transactions. MutationAttempts
is still the only durable verdict, retry and Safety Fence authority. No new
ledger, lifecycle persistence, Claim, Generation or spending authority exists.

## Evidence interfaces for dependent adopters

1. `Evidence.get_agent_binding/2` returns decoded Agent facts paired with their
   own retained observation. Retention failure returns a gap.
2. `Evidence.retained_agent_binding/2` restores one exact persisted identity;
   it neither reads the game nor restamps acquisition time.
3. `Evidence.recovery_agent_binding/2` explicitly reuses eligible retained
   credit facts for an attempt, including an older still-usable component when
   a newer acquisition is malformed. Otherwise it requests one governed safety
   read through the existing mechanism. Its acquisition owner is Ship Execution;
   Fleet-level owners retain their own governed acquisition responsibility.
4. `Evidence.recovery_proof/4` now derives `agent_credits` coverage only from
   a matching retained `get-my-agent` resource with valid nonnegative integer
   credits and the owning Agent's symbol. Ship coverage remains source-derived.
   Composite assembly performs no reads and reports usable, unusable and missing
   components. Both original acquisition times survive partial expiry and
   identity-based restoration.
5. Final MutationAttempts validation requires retained sources for refuel/jump,
   including direct ledger calls without selected-action metadata. Stripped
   sources and copied/widened coverage cannot produce any recovery verdict.

Buy/sell and refit can adopt these exact bindings without reconstructing
timestamps or copying attempt dependencies. Other existing families' helpers
remain for their own tickets and #575's final contraction.

## Actual verification

All commands sourced `scripts/_toolchain.sh`. Private writable build:
`MIX_BUILD_PATH=/tmp/opencode/567-build`. Prepared PostgreSQL 17 database:
`DATABASE_URL=postgres://postgres:postgres@localhost:5567/spacetraders_567_test`.
Container: `spec-502-567-postgres`; canonical boot port: `PORT=4567`.
Full transcripts are retained under `/tmp/opencode/`.

| Proof/check | Result | Transcript |
| --- | --- | --- |
| First composite Evidence tracer | Red: 1 selected failure, credit source had no coverage; green: selected pass | `567-composite-red.log`, `567-composite-green.log` |
| Exact family recovery progression | Red: 41 tests, 2 failures, eligible credit facts reacquired; green: 41 tests, 0 failures | `567-progression-red.log`, `567-progression-green.log` |
| Direct composite ledger invariant | Red: 2 selected failures, unretained assertions accepted; final green covers all three verdicts | `567-ledger-valid-red.log`, `567-targeted-final.log` |
| Restart reuse after partial acquisition | Red: 2 selected failures, malformed latest source hid valid retained credits; final green | `567-credit-reuse-red.log`, `567-targeted-final.log` |
| Targeted regression `mix test` with the six files below, `--seed 0 --trace` | **Exit 0; 138 tests, 0 failures** | `567-targeted-final.log` |
| Final `scripts/verify` | **Exit 0; 833 tests, 0 failures; seed 385515; 284.7 seconds ExUnit**. Compile, format, generated models/inventory, transport boundary and boot pass | `567-canonical-final.log`, `COMMAND_EXIT=0` |

Targeted files: `owned_intent_recovery_test.exs`, `fleet_intents_test.exs`,
`mutation_attempts_test.exs`, `ship_execution_durability_test.exs`,
`recorded_ship_runtime_test.exs`, and `api/recorded_dispatch_test.exs`, all under
`test/spacetraders/`.

The targeted run preserves independent PostgreSQL preparation/marker/outcome
visibility, interruption and eight-way retry/admission contention, authority-loss
and stale-callback regressions. New family cases prove retained Ship plus credit
lineage, credit retention failure, partial expiry without hidden reads, one retry
under repeated live/boot wakes, and Bounded Unknown-to-accepted historical
reconciliation during Emergency Stop. Bounded Unknown accounting in those cases
is expressly a controlled fixture, not a production worst-case price rule.

Earlier diagnostic results remain inspectable: `567-targeted.log` has one
malformed jump-response fixture failure and a subsequently deleted unused-helper
warning; `567-ledger-red.log` has an invalid test invocation of accounting for
accepted/absent. Neither is represented as meaningful implementation-red proof.
`567-canonical.log` passed 829 tests before final retained-credit reuse coverage;
the final gate above supersedes it.

## Remaining boundary

No known #567 acceptance gap remains. Combined all-family qualification belongs
to #576, and remaining family adoption/contraction stays on its native tickets.
This does not resolve #502's separate worst-case credit-exposure/repricing rule,
certify Fleet allocation or profitable autonomy, or satisfy Gates 2–5 and the
Operator-approved multi-day live trial. No deployment or gameplay trial occurred.
