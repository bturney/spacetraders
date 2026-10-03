# Recorded Ship execution qualification — #507

## Readiness and scope

This increment qualifies loss-safe recorded Ship dispatch and conservative
re-entry for Operator review. It does **not** certify all of Gate 1, independent
Fleet Allocation, net profitable trading, C02/C05/C06, or reset-to-reset autonomy.
The parent [#502](https://github.com/bturney/spacetraders/issues/502) remains open.
No production operations were performed.

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
committed action/attempt evidence. SQL and API telemetry interrupt execution at
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
