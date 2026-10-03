# Recorded Ship execution qualification — #507

## Readiness and scope

This increment qualifies loss-safe recorded Ship dispatch and conservative
re-entry for Operator review. It does **not** certify all of Gate 1, independent
Fleet Allocation, net profitable trading, C02/C05/C06, or reset-to-reset autonomy.
The parent [#502](https://github.com/bturney/spacetraders/issues/502) remains open.
No production operations were performed.

## PR review follow-up: admission and deterministic qualification

This section supersedes the original phase-hook and timing descriptions below.
Follow-up source base: `4ce4da31a54a322caedf91b496d1dcf8e8357956`.

**Final transport admission linearizes at successful completion of
`RecordedDispatch.authorize_transport/1`'s transaction.** The earlier
sent-or-unknown marker is durable uncertainty, not this final permission. A
completed revocation before final authorization prevents transport. If final
authorization wins first, its one request is already admitted and may reach the
adapter or complete after Emergency Stop. That request cannot be recalled;
restart still reconciles its marker from game evidence instead of blindly
sending it again. Stop/drain rollout language refers to this exact boundary.

Four deterministic ordering cases cover Emergency Stop and Claim revocation
winning before authorization or losing to completed authorization. A fifth
overlap case pauses **inside** the final transaction after authority validation,
starts Emergency Stop, observes its pending cache suppression, and proves its
durable Strategy write waits behind authorization's shared row lock using the
independent observer's `pg_blocking_pids` check of both pinned backends. Releasing
authorization permits exactly one orbit; production boot adds none. These
cases deliberately orchestrate concurrency rather than depending on scheduler
luck to reproduce a race.

The interruption matrix now consumes named semantic telemetry in
RecordedDispatch and MutationAttempts. `preparation_written`, `marker_written`
and `outcome_written` are pre-commit phases. `prepared`, `marker_committed`,
`transport_authorized` and `outcome_committed` are post-commit phases. Outcome
publication never labels a nested caller transaction committed. The independent
PostgreSQL observer still verifies actual durability; no Ecto SQL/parameter
strings select the interruption phase.

RateLimiter accepts a local monotonic-millisecond clock with `now/0` and
`sleep/1` callbacks, defaulting to the existing System/Process implementation.
Its public `acquire/1` tests use controlled time: the complete 32-token initial
grant, blocking after drain, no grant one millisecond before each refill, and
grants at 500/1000/1500ms. No correctness assertion depends on wall-clock elapsed
time or the limiter's rounded proposed sleep duration.

Ordinary regression coverage runs the actual qualification, EvidenceScheduling
and ResourceAcquisition ExUnit files consecutively **in the same child VM**, in
both file orders, repeated twice. Twelve suite runs execute 164 cases and use
the genuine setup/on_exit lifecycle. After every suite it verifies exact clock
and RuntimeAuthority config restoration, no owned runtime/Ship processes, fresh
shared Sandbox ownership for a new observer and private Req ownership. After
qualification it also checks admission caches and empty volatile API admissions.

This proof failed against the unchanged original PR: all 23 runtime cases
passed, but teardown changed absent `:clock` configuration into `{:ok, nil}`.
The fixture now restores key absence as well as values. It no longer switches
Req into global shared mode; explicit allowances cover only its runtime actors.
The repeated-order proof then passes. This establishes and corrects a real
global-state leak; it **does not claim** that the leak caused either historical
CI ResourceAcquisition or Sandbox-ownership failure. Neither failure was
reproduced in this controlled proof.

Feedback targeted receipt: `507-feedback-deterministic-green.log`, 35 outer
tests, 0 failures, plus the 164 ordered child cases. Original-source lifecycle
red receipt: `507-feedback-lifecycle-red.log`. Controlled-clock red receipt:
`507-feedback-rate-red.log`. The 799-test results below identify the earlier
revision.

**Known open failure on this revision.** The canonical gate is red at this
revision: `507-feedback-canonical.log`, 806 tests, 1 failure. It is not a
qualification regression. Inside the ordered-suite proof, the **second** run of
`ResourceAcquisitionTest` in one child VM returns
`{:error, :resource_acquisition_unavailable}` for "active Strategy discovers a
remote extraction Waypoint for a new Agent", expecting a `waiting` Intent.
`FleetResources.reconcile/5` collapses every failure into that atom, so the
receipt does not name the failing guard. The same file passes standalone, in the
first ordered run, and in `507-stop-repro-1.log`. Prime suspect: one seeded
remainder — a retained Observation/ObservationDemand, a live
`SpaceTraders.Evidence.ReadCoordinator` dedup entry, or CapacityGovernor state —
that a same-VM repeat run does not clear and that makes `FleetResources.reconcile`
see unavailable inputs. `Evidence.read/3` coalesces concurrent identical reads
through a globally named coordinator, and `DataCase` only rolls back the
transaction, so this is the first place to instrument. Do not widen the search
to unrelated flaky tests; see the handoff.

Feedback two-axis review: Standards found no actionable findings. Spec identified
that a pending Stop task was not itself proof of row-lock contention. The overlap
test now observes the actual PostgreSQL blocking relationship before releasing
authorization, rather than depending on a zero-time task yield.

Source base: `c97fc58d6c4e3986b80dbacfe4998cf395449811` (merged #506).
Implementation revision: the commit containing this report on
`feature/507-recorded-ship-qualification`. The retained patch and command logs
identify the qualified source independently of the branch name.

The final gate records staged source tree
`33bf88ac6bd0f5b8f576f7a796e11ca50f838587`. Runtime and test blobs in that tree
are the delivered implementation; subsequent report-only edits add the final
receipts and evidence URL. The retained source patch reconstructs the reviewed
runtime/test change against the exact base above.

[Durable report, source patch and complete terminal transcripts](https://gist.github.com/bturney/d1416360b9b5a74ea07ab554ccfa068a)
contain both red reproductions and the final passing results.

Retain the original
[baseline findings](https://github.com/bturney/spacetraders/issues/503#issuecomment-5924166162)
and [executable positive and negative evidence](https://gist.github.com/bturney/e588032ca5864e94b58edd260e161a22).
The narrower predecessor receipts are
[recorded dispatch](recorded-ship-dispatch-504.md) and
[validated recovery](ship-recovery-506.md).

## Production-path proof

`test/spacetraders/recorded_ship_runtime_test.exs` is ordinary ExUnit coverage.
Each scenario creates an authenticated Operator, mints through LiveView, activates
the real Strategy preset, and lets production Reconciler, DemandScheduler and Ship
Execution select work from the stateful `RuntimeBaselineGame`. No portfolio is
injected into these scenarios. The fixture owns only game state and actual
transport receipts. The scenario starts the real PostgreSQL singleton authority.

An independent Postgrex session has a different backend from the sender and sees
committed action/attempt evidence. Semantic and API telemetry interrupt execution at
the specified boundary; they never provide work or recovery decisions. Restart
discards Reconciler, DemandScheduler, ShipServers and volatile Capacity Governor
admissions, then invokes production coordination and ShipServerBoot. Controlled
observation time advances past the interruption; it does not restamp old evidence.
This proves runtime reconstruction, not isolated process-only capacity recovery.

| Interrupted boundary | Independently committed evidence | Expected and actual orbit effects after restart |
| --- | --- | --- |
| Before preparation / inside preparation write | No selected Ship attempt | One first dispatch |
| After preparation commit / inside send-marker write | Original `prepared`, no send timestamp | One dispatch of the original attempt |
| After send-marker commit / before transport accepts | Original `sent_or_unknown` | Fresh absence proof, one consumed retry, one effect |
| After game acceptance / response delivery / inside outcome write | Original `sent_or_unknown`; accepted effect retained by game | Fresh acceptance proof; one effect, no replay |
| After outcome commit | Original `succeeded` | One retained effect, no replay |

The observer's pre-death snapshot is unchanged immediately after sender death.
Each receipt records the phase, sender/observer backend IDs, attempt identities,
before/after dispositions, retry linkage, and expected/actual external effects.
The deterministic matrix uses orbit to isolate the common recorded protocol;
adapter and owned-recovery regressions retain their operation-specific scope.

## Violations exposed and corrected

1. **Authority loss after send-marker commit:** a stopped sender still reached
   orbit transport. The failing receipt recorded one effect where zero was
   required. RecordedDispatch now rechecks selected action, Claim, Generation,
   Revision, Emergency Stop, singleton and request bindings immediately before
   returning control to transport. A post-marker refusal preserves the marker
   and appends `ambiguous` with `suppressed_before_transport`; it never rewrites
   admitted history as `not_sent` or manufactures absence/retry evidence.
2. **An obsolete callback resurrected a changed selection:** suppression used a
   stale Intent snapshot to restore the old action, which boot subsequently
   retried. Intent transitions now lock the row and require the current selected
   action to match the caller's snapshot. Stale callbacks cannot replace it.
   Refit response handling carries the committed selected snapshot explicitly:
   Elixir `with` failure branches cannot see its rebound value. A legitimate
   purchase rejection can still persist its durable API-capacity wait.
3. **Proven absence could leave Emergency Stop resume permanently blocked:**
   recovery tried the absent retry while stopped and retained the old action.
   Its owner now atomically retires that unused retry in MutationAttempts and
   clears the selected action. The original absence proof and disposition remain
   append-only. Resume preparation then retires old Intents rather than releasing
   their queued actions. Fresh-plan admission remains a separate Fleet Allocation
   obligation; the runtime proof does not inject a winning plan to force resume.

The authority matrix revokes Claim, selection, Revision, Emergency Stop,
Generation or actual singleton permission after preparation and after committed
send admission. Every captured action produces zero transport effects; boot
cannot release it under revoked authority. Where fresh absence records retry
eligibility, current-authority preparation still refuses it.

At the agreed Ship Execution seam, eight concurrent retry preparations consume
one absence permission, and eight concurrent dispatch callers produce one
transport effect. Repeated production boot does not send another orbit. The
existing adapter matrix rejects enclosing caller transactions for every
implemented Ship action; independently committed runtime snapshots prove that
game-accepted effects are not hidden behind caller rollback.

An unresolved spending attempt protects its Ship and shared Agent credits. A
separately claimed dependent Ship cannot even prepare spending; its selection
remains untouched. Another independently claimed Ship executes its posture
outcome through normal Intent boot reconciliation. Its transport receipt is
retained while the original fence stays active. These lower-seam Claims establish
independent execution authority, not whole-Fleet allocator correctness. Existing
transfer and legacy-recipient coverage retains the receiving Ship/resource scope;
identified uncertainty is not widened to all unrelated Ship work.

## Actual compatibility and single-active cutover

There is no new schema migration in #507. Migration `20261001010000` already adds
the nullable `intents.mutation_attempt_id` UUID foreign key/index and permits
`not_sent` in the existing attempt/outcome constraints. This increment uses the
existing states and JSON evidence fields. Old missing-attempt rows remain valid;
new recovery adopts them conservatively into the **same** MutationAttempts
ledger, preserving historical result/timestamps without inventing a send marker
or retry permission. Missing recipient identity retains the necessary wider
Agent resource protection until authoritative evidence can narrow it.

The actual delivery mechanism is `scripts/deploy` → `scripts/deploy-host` plus
the committed Compose files. `deploy-host` pulls the image and **stops `web`**
before starting the new composition. `web` has a 60-second stop grace period;
PostgreSQL must be healthy and `migrate` must succeed before `web` starts.
`SpaceTraders.Release.migrate/0` starts only the repository/migrator, not the
autonomous runtime. The new web boot starts admission caches and singleton
authority, production coordinators and Ship reconstruction from PostgreSQL.

An authorized rollout must follow this boundary:

1. Engage durable Emergency Stop for every affected Operator. Inventory selected
   actions, attempts, active fences and pending waits through an independent
   PostgreSQL observer. Let already-admitted calls finish; any killed/timed-out
   call remains unknown. Emergency Stop cannot recall a game-accepted request.
2. Stop/drain the old `web` runtime and verify it is no longer issuing requests or
   holding singleton authority. Keep PostgreSQL and a verified backup intact.
   No old/new binary overlap and no hot-code deployment is qualified here.
3. Migrate and start exactly one new runtime with the stops retained. Reconstruct
   prepared, unknown and legacy selected actions. Verify linked ledger state
   independently, then obtain governed authoritative evidence for **every**
   required dependency, including credits or receiving resources where declared.
4. Reconcile forward before dependent resume. Already accepted work is not
   replayed; proven absence does not override revoked authority. Invalid or
   incomplete facts retain scoped protection and truthful blocked state. Resume
   preparation may proceed only after obsolete selections have been reconciled;
   fresh Fleet planning must authorize any later release of mutation admission.
5. On failure, keep admission stopped and recover with a fixed compatible binary.
   The current `deploy-host` refuses automatic and manual image rollback once
   PostgreSQL authority has advanced: **the supported operational cutover is
   forward-only**. Retain the additive schema and all ledger evidence.

An older binary may tolerate the added nullable column, but pre-#504 binaries
retain unsafe dispatch and do not understand `not_sent`; #506 lacks the three
corrections above. Binary readability is not permission to resume either one.
Any separately authorized offline rollback must keep old dispatch physically
stopped/drained. Schema rollback would reject retained `not_sent` history; never
delete/rewrite outcomes to make rollback succeed or restore a backup over effects
that the game has already accepted. `/health` 200 establishes service health,
not safe gameplay or Strategy outcomes.

## Verification receipts

Commands source `scripts/_toolchain.sh` and use the prepared PostgreSQL database
`spacetraders_test`. Elixir has no configured separate typechecker;
`MIX_ENV=test mix compile --warnings-as-errors` ran after each runtime correction.
Verbose transcripts are retained; the command exit status is the verdict.

| Command / proof | Terminal result | Log under `/tmp/opencode/` |
| --- | --- | --- |
| Runtime matrix + Ship durability | Exit 0; 35 tests, 0 failures | `507-regression-proof.log` |
| API adapters/spec + owned recovery + Intervention | Exit 0; 62 tests, 0 failures | `507-neighbor-regressions.log` |
| Compilation / generated models and operations | Exit 0; generated contents unchanged; standalone successful compilation has no stdout | `507-codegen.log`; final canonical transcript includes compilation |
| Post-marker stop before correction | Exit 2; 11 tests, 1 failure; expected zero orbits, actual one | `507-post-marker-stop-red.log` |
| Changed selection before correction | Exit 2; 22 tests, 1 failure; obsolete retry reached transport at boot | `507-selection-boot-diagnosis.log` |
| Stopped absence before correction | Exit 2; 1 selected test failed; resume still required reconciliation after proven absence | `507-stopped-absence-resume-red.log` |
| Explicit trading diagnostic | Exit 0; 1 test, 0 failures; one 40-unit purchase/sale, credits 175,000 → 175,800, fuel 200 → 20, Mission Control “Outcome status unknown” | `507-trading-qualification.log` |
| Reviewed runtime file | Exit 0; 23 tests, 0 failures | `507-reviewed-runtime.log` |
| Refit response snapshot / runtime / rate limiter | Exit 0; 37 tests, 0 failures | `507-refit-timing-green.log` |
| Canonical `scripts/verify` | **Exit 0; 799 tests, 0 failures; seed 710537; 106.7 seconds ExUnit.** Compile, formatting, 95 models, operation inventory, transport boundary and `/health` HTTP 200 pass. | `507-canonical-confirmed.log` |

Earlier gate attempts are retained too. The first reported 799 tests and three
failures: two refit 429-wait assertions exposed the stale pre-selection snapshot
in a `with` failure branch (corrected as above), and the untouched RateLimiter
wall-clock lower bound measured 999ms against 1000ms. That timing file passed in
the targeted 37-test run without an assertion change. The next gate exited 2
with 799 tests and one API Client shadow-fingerprint correlation failure. The
client file passed in isolation at the same seed 595597. A clean-source
`c97fc58` comparison at seed 595597 passed 774 tests; this comparison does **not**
reproduce or establish the cause of the correlation failure. The final unchanged
gate above passed. Logs: `507-canonical-verify.log`, `507-refit-isolated.log`,
`507-canonical-final.log`, `507-client-matching-seed.log`,
`507-main-comparison.log`. No test assertion or verification-tool behavior was
weakened to obtain the final result; repeats followed concrete failing checks.

Two-axis `/code-review` covered the complete staged increment. Spec reported no
actionable findings. Standards reported one nonblocking local clock-advancement
duplication; it was consolidated in this test file. The refit correction stays
within the reviewed stale-selection contract and is verified by existing refit
regressions and the final gate.

The new positive trading receipt does not erase archived negative runs from
#503/#504/#505. Inventory fuel was consumed; 800 cash credits are not demonstrated
net profit after replenishment. Callback ordering, partial coverage, full
capability, economics, Strategy semantics, allocation, product outcomes and
reset-to-reset gates remain unproven at their full contract scope.

The canonical boundary check and adapter tests cover current caller contraction:
Ship actions route through RecordedDispatch; raw Ship credentials/callback retry
entry points are refused. MutationAttempts is still the sole recovery ledger.
No metadata-only alternate ledger or test-only recovery coordinator was added.

After Operator review of this increment, the issue's next checkpoint is one
architecture pass over these changed runtime areas, recording its finite Strong
candidate list and tracing every selected finding through the agreed scoped
design/spec/ticket flow. That follow-on work does not certify later parent gates.
