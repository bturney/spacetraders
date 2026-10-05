# Recorded Ship recovery qualification — #576

Integrated qualification for the #561/#562 increment of
[#502](https://github.com/bturney/spacetraders/issues/502) (Gate 1, C03/C04/C12).
This receipt does **not** certify Gate 1 in full, Gates 2–5, or deployment.

## Revision

- Source base: `4ca2c25` (`opencode/kimaki-spec-502-integration`, after #566–#575).
- Qualified revision: the commit containing this receipt on
  `opencode/kimaki-spec-502-576`. Changes are test-only plus this receipt; no
  `lib` change.
- Environment: every shell sourced `scripts/_toolchain.sh`;
  `MIX_BUILD_PATH=/tmp/opencode/576-build`;
  `DATABASE_URL=postgres://postgres:postgres@localhost:5576/spacetraders_576`
  (container `spec-502-576-postgres`); `PORT=4576`.

## Tests added

All go through production runtime/public seams (`Intents.reconcile/5`,
`Intents.intervene_navigate/5`, `FleetAcquisition.reconcile/4`) and the game
HTTP stub. Each passed on first run: characterization, no defect found.

| Test | Gap closed |
| --- | --- |
| `owned_intent_recovery_test.exs` "a game-rejected market cargo dock blocks its selection without trading or replay" | #575 risk: cargo dock rejection through shared `block_intents/2`. One `dock` POST, no purchase, attempt `rejected`, Intent `blocked` (`in_transit`), selection cleared, stale callback sends nothing. Mutation check: replacing the shared `block_intents` continuation with `:ok` fails only this test (`576-dock-rejection-mutant.log`, exit 2). |
| `manual_intervention_test.exs` "boot/arrival recovers a lost intervention Navigate response from retained evidence without replay" | Manual Intervention live vs boot recovery of an interrupted (lost-response) send: same attempt reconciled `accepted` from a retained source, fence released, no second navigate, intervention link kept. |
| `fleet_acquisition_test.exs` "recovers a lost purchase response …" (added assertions) | Fleet acquisition recovery creates no Intent and no selected Ship action; its attempt is the agent's only attempt. |

## Contract-to-test matrix

Files are under `test/spacetraders/` unless noted.

| #576 criterion | Covering tests |
| --- | --- |
| Interruption before/after preparation commit, send-marker commit, final admission, transport effect, response, outcome persistence; independent durable observer | `recorded_ship_runtime_test.exs` "runtime death at #{phase} reconstructs committed evidence without blind replay" (all #507 phases, independent Postgrex observer); `ship_execution_durability_test.exs` first-accepted, accepted-retry and ambiguous sender-death cases |
| Revocation/loss of Claim, Revision, Emergency Stop, Generation, singleton; stale callback; concurrent retry/admission | `recorded_ship_runtime_test.exs` "#{loss} lost at #{phase} …", "#{loss} race: #{winner} linearizes first …", Stop/final-authorization overlap; `ship_execution_durability_test.exs` "#{loss} authority lost after preparation …", "concurrent retry preparation and dispatch consume one permission and one transport effect"; `owned_intent_recovery_test.exs` "a stale event identity cannot even adopt …", "an obsolete callback cannot clear a newer retry …"; `api/recorded_dispatch_test.exs` transfer revalidation |
| Historical reconciliation does not restore revoked send authority | `fleet_refit_test.exs` "bounded historical effect reconciles during Stop without restoring authority", "absence during Stop retires retry …"; `transfer_recovery_test.exs` "lost receiver Claim retires proven absence …"; `resource_recovery_test.exs` "persisted resource absence retires under Stop"; `recorded_ship_runtime_test.exs` Emergency Stop resume preparation |
| Accepted / absent / Bounded Unknown with exact retained Evidence | `mutation_attempts_test.exs` "reconciliation durably distinguishes accepted, absent, and Bounded Unknown outcomes"; `owned_intent_recovery_test.exs` "runtime re-entry can resolve Bounded Unknown …", "#{kind} Bounded Unknown retains exact composite proof …"; per-family exact-source tests below |
| Failed retention cannot resolve | `owned_intent_recovery_test.exs` chart retention failure, "#{family} #{gap} retention failure …", "#{kind} recovery cannot settle a retained Ship when credit retention fails"; `resource_recovery_test.exs` failed observation retention; `transfer_recovery_test.exs` receiving read retention failure; `fleet_acquisition_test.exs` "failed #{subject} retention …" |
| Malformed / stale / future / wrong-Generation evidence | `owned_intent_recovery_test.exs` "exact evidence rejects wrong Generation, pre-dispatch and future acquisitions", "#{trigger} rejects a malformed owned read …", "malformed credits cannot settle refuel …", chart provenance cases; `mutation_attempts_test.exs` "stale, future and pre-send conclusions cannot release a mutation fence"; `fleet_acquisition_test.exs` invalid age/Generation/coverage/malformed credits |
| Partial expiry | `owned_intent_recovery_test.exs` "partial expiry preserves usable exact bindings …", "#{kind} composite proof reports partial expiry …", "#{family} partial acquisition expiry …"; `fleet_acquisition_test.exs` "partial expiry replaces only the unusable Fleet component …"; `transfer_recovery_test.exs` receiver-read expiry |
| Falsely claimed dependency coverage | `owned_intent_recovery_test.exs` "final ledger validation rejects stripped or falsely widened retained sources", "final validation uses durable dependency scope …"; per-family "ledger rejects unretained conclusions" (refuel/jump, resource, refit, transfer); `fleet_acquisition_test.exs` "Fleet proof derives coverage from the retained owned subject, not claimed dependencies" |
| Live and boot equivalence: navigation/posture | `owned_intent_recovery_test.exs` "#{trigger} preserves the original bound source …" (boot/arrival/cooldown/intent_retry), "prepared work resumes its original attempt …" |
| Refuel/jump | `owned_intent_recovery_test.exs` "#{kind} proven absence consumes only one retry through repeated boot and live wakes", "#{kind} boot recovery retains …" |
| Buy/sell | `owned_intent_recovery_test.exs` "#{kind} live and prepared boot callbacks advance the same selection only once", "#{kind} proven absence consumes one retry through boot and live wakes", market dock progression and **new** dock rejection |
| Contract/Construction delivery | `owned_intent_recovery_test.exs` "#{family} accepted delivery reenters the selected action on #{trigger}", "#{family} proven absence retries once through the same live response continuation" |
| Transfer | `transfer_recovery_test.exs` "absent transfer retries once through the selected live and boot progression", "#{trigger} retains exact two-Ship acceptance …" |
| Scans/chart | `owned_intent_recovery_test.exs` "prepared scan boot and live dispatch retain the same returned Intelligence exactly once", chart restart cases |
| Resource actions | `resource_recovery_test.exs` "#{trigger} resource retry applies the same rejection continuation …", "prepared #{kind} boot dispatch keeps the same response continuation …" |
| Refit | `fleet_refit_test.exs` "#{kind} live, prepared boot, and absent boot share one effect and continuation" |
| Manual Intervention | `manual_intervention_test.exs` restart rearming case and **new** boot/arrival lost-response recovery; `api/recorded_dispatch_test.exs` "an authenticated Intervention dispatches …" |
| Fleet acquisition: shared Evidence contract, separate ownership | `fleet_acquisition_test.exs` (17 tests, incl. **new** no-Intent/no-selection assertions) |
| Independent Ships continue except real dependency fences | `ship_execution_durability_test.exs` "unresolved shared credits fence dependent spending while independently claimed Ship execution continues"; `mutation_attempts_test.exs` "ambiguous Ship mutation fences only dependent Ship mutations", Waypoint and Contract fence scope; `fleet_intents_test.exs` sibling credit fence |
| No obsolete bypass / second lifecycle | `test/mix/tasks/verify_boundary_test.exs` progression-bypass and retired-send cases; `verify.boundary` in the gate; `api/recorded_dispatch_test.exs` raw credentials/callback retries refused, enclosing-transaction refusal for every Ship operation |
| Canonical gate with durable result | Below |

## Gate result

| Check | Result | Log (`/tmp/opencode/`) |
| --- | --- | --- |
| Market recovery incl. new dock rejection | Exit 0; 106 tests (17 selected), 0 failures | `576-dock-rejection.log` |
| Dock rejection mutant (shared continuation removed) | Exit 2; 1 failure, the new test only | `576-dock-rejection-mutant.log` |
| Manual Intervention | Exit 0; 4 tests, 0 failures | `576-intervention-recovery.log` |
| Fleet acquisition | Exit 0; 17 tests, 0 failures | `576-acquisition.log` |
| Canonical `scripts/verify` | **Exit 0; 954 tests, 0 failures; seed 157966; 220.7 s.** Ordered-fixture lifecycle proof, generated models (95) and operation inventory, `verify.boundary`, `/health` 200 all pass | `576-canonical.log`, `576-canonical.status` |

Each `.log` has a `.status` sibling with command, exit code and environment.
Runner: `576-run.py`.

## Remaining unproven or blocked

- **Blocker:** the worst-case credit-exposure (spending-authority) rule in #502
  is unresolved. It remains a deployment-qualification blocker. Bounded Unknown
  tests use test-only accounting examples, not a production exposure guarantee.
- No production operation, deployment, or live gameplay trial occurred.
  `/health` 200 is service health only.
- The interruption matrix and revocation races are exercised on orbit (common
  protocol) only; other families are covered at boot/live re-entry and ledger
  seams, not at every interruption phase.
- Live/boot equivalence is shown per family by driving `Intents.reconcile/5`
  with each trigger, not by a full autonomous scenario per family.
- `RecordedAction` still lives under `Fleet.Intents` and is called from
  `api.ex`; the boundary check pins that one exception (#575).
- Nothing here implies coherent allocation, profitable autonomy,
  Market/resource snapshot consolidation, capacity deepening, outcome-ledger
  completion, or any of Gates 2–5.
