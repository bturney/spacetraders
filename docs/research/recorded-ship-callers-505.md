# Recorded Ship callers — #505

## Confirmed boundary

The Operator [confirmed recorded-dispatch-only scope](https://github.com/bturney/spacetraders/issues/505#issuecomment-5939648932)
after reviewing the spending risk below. #505 preserves existing spending checks;
new spending authority remains [parent #502 work](https://github.com/bturney/spacetraders/issues/502#issuecomment-5939649595)
before deployment qualification. The credit floor remains a Hard Constraint.
The initial return is resolved; #504 was already closed and #505 is ready again.

## Scope and agreed seams

Starting revision: `dfd5691b38dbec8d6a08b3da465d92bb05cf5cab` (fresh
`origin/main`). #504 is closed and its recorded-dispatch protocol is present.
The previous `feature/503-runtime-baseline` branch was already merged; this
increment uses `feature/505-recorded-ship-dispatch` from main.

[Issue #505](https://github.com/bturney/spacetraders/issues/505), the approved
[#503 baseline](https://github.com/bturney/spacetraders/issues/503#issuecomment-5924166162),
and [parent #502](https://github.com/bturney/spacetraders/issues/502) fix the
testing seams: authenticated Operator/runtime scenarios with controlled game
transport, real PostgreSQL commits and an independent observer; existing public
Intent/family interfaces; and the generated operation/no-bypass verification
boundary. TDD extends those agreed seams. Lower-level adapter tests retain their
narrow request/response scope and do not claim Fleet capability reachability.

## Implementation-revision caller inventory

| Family | Implemented selected actions | Current send callers |
| --- | --- | --- |
| Posture and movement | orbit, dock, Flight Mode, navigate, jump, warp, refuel | `Fleet.Intents`: initial, prerequisite, and proven-absent retry |
| Cargo | buy, sell, Contract delivery, Construction supply, transfer | `Fleet.Intents`; delivery adapters in `Contracts` and `Fleet` |
| Intelligence and resources | Waypoint scan, chart, survey, extraction with/without Survey, siphon, refinement | `Fleet.Intents` |
| Readiness | module install/remove and purchase-sourced refit prerequisites | `Fleet.Intents` |

The generated manifest also classifies Ship/System scans, mount install/remove,
repair, and jettison as Ship-owned. Ship/System scans, mounts and repair have no
implemented runtime mutation caller. Jettison has a low-level API adapter/test,
but no supported root Intent or runtime caller. Adoption must explicitly reject
unsupported execution rather than inventing these capabilities. Fleet-owned
negotiation, acceptance, fulfillment, acquisition and scrapping remain under
their existing owners.

## Initial return: spending admission (scope decision resolved)

The initial investigation returned #505 for clarification. At starting main, the shared
#504 boundary qualifies orbit's non-spending consequences. Its
`authority/2` checks only `posture_consequence_authorized/1`, which validates the
Revision's supported rule vocabulary. `prepare/3`, `prepare_retry/3`, and
`API.dispatch_recorded/1` are deliberately orbit-only. Mechanical caller adoption
does not supply a justified worst-case exposure for credit-bearing actions.

### Executable public-interface evidence

`test/integration/ship_spending_admission_proof.exs` is deliberately opt-in
(`_proof.exs`, following #503's convention). It exercises the existing public
`Intents.request_commitment_round_trip/5` with a real current Claim, Generation,
Revision, portfolio and protected credit floor. The fixture is an admitted
portfolio; this is a lower public-module proof, not authenticated end-to-end
Fleet allocation qualification.

```text
Authoritative credits           2,000
Active Hard Constraint floor    1,000
Purchase Reservation               50   (5 units x observed price 10)
Existing exposure allowance       800   (50 + 500 fuel + 250 bounded loss)
Existing eligibility             PASS  (2,000 - 800 >= 1,000)

Market reprices before the request: 220 per unit
Game accepts 5 units, spends 1,100, leaves 900 credits
MutationAttempts: succeeded; Intent: completed
Returned Intent price: 10; authoritative transaction total: 1,100
Credit-floor proof: FAIL
```

The stateful transport checks the actual selected quantity and available funds;
it preserves Cargo capacity and applies the accepted effect. The game request
carries exactly `symbol` and `units`. The lower seam proves that even an action
which passes the existing eligibility calculation and preflight can spend
protected credits. Better record/commit sequencing alone cannot enforce that
consequence authority.

### Source chain

| Source | Evidence |
| --- | --- |
| `priv/spec/SpaceTraders.json:2904-2924`; generated `api/request/purchase_cargo_request.ex` | Purchase supports `symbol` and `units`, no conditional price or total ceiling. |
| `FleetStrategy.StandingAuthority` | Hard Constraints must be proven from consequence bounds; conditional price guarantees are explicitly unenforceable. |
| `FleetExecution.reservation_covers_exposure?/3` | Existing Reservation + fixed fuel/loss allowance is the eligibility calculation, not a bound enforced by the game. |
| `Fleet.Intents.executable_cargo_units/4`, `claim_intent_action/3`, `validate_market_transaction/3` | Quantity uses the observed price and credits. Selection preserves that price but no maximum exposure authority. Transaction validation checks identity/quantity, not the charged price; completion retains the observed price. |
| `API.RecordedDispatch.authority/2`; #504 report | The activated non-spending path only validates constraint vocabulary. #504 explicitly leaves other adapters' consequence admission to #505. |

The inventory also exposes refuel, jump, and module install/remove as implemented
credit-bearing callers. This proof qualifies only the purchase failure; it does
not assert those other families fail under the same controlled scenario.

### Precise question to resolve

**What approved, evidence-bound worst-case credit exposure must an existing
credit-bearing Ship action present to recorded send admission, and is defining
that contract authorized in #505 or a prerequisite decision?** The answer must
explain price/fee changes between observation and send while retaining the active
Hard Constraint and supported outcomes. Treating a Listing as a guaranteed bound
would silently weaken Standing Authority; suppressing every existing spending
outcome would violate the adoption/preservation scope.

This was the independent authority/interface-contract risk returned before
expansion. The Operator resolved the scope question above: adopt recorded dispatch
without redefining spending authority. This risk remains visible and unqualified;
it no longer blocks the caller migration.

## Initial investigation receipt

Production source qualified: `dfd5691b38dbec8d6a08b3da465d92bb05cf5cab` plus
the added report and opt-in proof.
Elixir has no separate configured typechecker; use warnings-as-errors compilation.
Full terminal logs are retained under `/tmp/opencode/505-*.log`.

| Command | Terminal result | Retained log |
| --- | --- | --- |
| `MIX_ENV=test mix compile --warnings-as-errors` | Pass. | `505-compile.log` |
| `mix test test/integration/ship_spending_admission_proof.exs --seed 0 --trace` | 1 test, 1 deliberate Hard Constraint failure; 0.9 seconds. Game credits 900 below the 1,000 floor; succeeded attempt/completed Intent. | `505-spending-admission-final.log` |
| `mix test test/integration/recorded_ship_dispatch_test.exs test/spacetraders/fleet_intents_test.exs test/spacetraders/fleet_transfer_test.exs test/spacetraders/manual_intervention_test.exs test/spacetraders/resource_acquisition_test.exs --seed 0 --trace` | 29 tests, 1 failure; 13.4 seconds. All 16 recorded-dispatch proofs, Market round trip, four transfer scenarios and two Intervention regressions pass. Remote-resource discovery returns `:resource_acquisition_unavailable` instead of a waiting Intent. | `505-existing-regressions.log` |
| `mix test test/integration/runtime_baseline_proof.exs --seed 0 --trace` | 1 test, 1 failure; 5.0 seconds. Discovery and restart continue, but zero purchases/sales, 175,000 credits, 80 fuel; Mission Control reports “Outcome status unknown.” Trading remains unqualified. | `505-trading-opt-in.log` |
| `scripts/verify` | Exit 2; 718 tests, 1 failure; seed 491951; 135.5 seconds. Same remote-resource discovery failure at `resource_acquisition_test.exs:170`. Formatting, compilation, 95 generated models, operation inventory, API boundary and HTTP `/health` 200 pass. | `505-canonical-verify.log` |
| `mix test test/spacetraders/resource_acquisition_test.exs --seed 0 --trace` in a clean `git archive` export of starting main | Exit 0; 6 tests, 0 failures; 3.2 seconds. | `505-clean-main-resource.log` |
| Identical five-file family command above in that clean-main export | Exit 0; 29 tests, 0 failures; 16.8 seconds. | `505-clean-main-families.log` |

The initial spending-proof run failed on an incorrect fixture expectation that
the Intent would remain unfinished (`505-spending-admission-proof.log`). The
corrected run inspects the actual completed Intent and reaches the intended
credit-floor assertion (`505-spending-admission-proof-2.log`); the final formatted
proof reproduces it. A temporary strengthened navigation-link assertion also
reproduced the known migration gap (`505-navigation-red.log`, 16 tests, 1 failure,
15 excluded); the original ordinary regression is unchanged.

Canonical and opt-in results are separate. No existing test is weakened, skipped,
or moved to hide its failure. The added proof uses the existing opt-in evidence
convention while the work awaits a scope decision.

The canonical failure is retained, not declared repaired or explained away.
Runtime source and existing tests are unchanged in this diff. Clean-main isolated
and matching family runs pass, so these runs do not establish a deterministic
cause for the remote-resource failure. The known canonical result remains **red**.

## Initial evidence review

`/code-review` reviewed the exact staged report/proof diff against starting main
once, using independent Standards and Spec reviewers. Standards found no
documented breaches or material smell findings. Spec found no findings: the
source-backed proof supports #505's explicit independent-risk return path; the
adoption criteria are deliberately unmet, with no false completion claim.

Evidence commit `d069500` recorded the initial return. The Operator subsequently
confirmed the migration boundary; the issue returned to `ready-for-agent`.

## Completed caller migration

`API.RecordedDispatch` now prepares every implemented Ship action and its allowed
retry through the same #504 protocol. `API.ShipAction` owns request encoding and
response decoding from the bundled operation inventory. Ship Execution supplies
the selected action and current root Intent. `MutationAttempts` remains the sole
attempt/outcome ledger.

```text
Ship Execution selects action + supplies root Intent
    |
RecordedDispatch.prepare       actual commit: selection + prepared attempt + linkage
    |
API.dispatch_recorded          capacity/protocol admission, outside caller transaction
    |
RecordedDispatch.admit_send    actual commit: current authority + sent_or_unknown
    |
SpaceTraders transport         no enclosing transaction; no transparent mutation retry
    |
MutationAttempts outcome       same attempt; append-only history
```

The shared adapter preserves paths, payloads, response structs, root authority,
request correlation, prerequisites, consequences and fence dependencies. Send
admission also verifies that the recorded request and operation match the selected
action; a linked but altered request cannot borrow another action's authority.
Retries retain the selection identity, consume the absent attempt's permission,
and link the next attempt in one commit. Current Claim or authenticated Manual
Intervention, Revision, Generation, singleton, Emergency Stop and selection are
revalidated at send. Caller transactions are explicitly rejected.

Transfer retains both current Ship authorities and the receiving Cargo capacity
Reservation. Ship Execution still reads physical presence and free receiving
Cargo before selection; admission revalidates the receiving Claim/version and
reserved quantity after preparation. Losing either suppresses send with `not_sent`
evidence. This is not a lock on Shared World State.

Send authority is resolved per Intent owner instead of through one Fleet-wide
gate. An authenticated Manual Intervention dispatches under its own authority
with no active Strategy Revision required, and records the active Revision only
when the Fleet already has one. A Fleet Commitment still requires an unfenced
current Generation, an active Revision, and a live Claim bound to both; a
fenced Generation, a retired Generation, a withdrawn Revision or a lost Claim
each suppress send with `not_sent` evidence rather than raising. Preparation
refusals that mean "this operator no longer owns the Ship" supersede the
preparing Intent through the existing lost-Claim path, so a caller can re-select
instead of dispatching someone else's authority.

The original `claim_intent_action`, action-specific retry sender and
transaction-held retry callback are removed. Token-only Ship methods,
`Contracts.deliver_goods` and `Fleet.supply_construction` are removed; Construction
observation/invalidation remains in its existing owner. The ledger's process-local
retry callback/context is removed. API Capacity still receives `Retry-After`
backpressure for recorded rejections, without a private HTTP retry.

### Executable coverage and public seams

- `verify.boundary` rejects retired sends and caller-owned attempt admission,
  including aliases. It checks the declared adapter set against every generated
  Ship-owner operation. Both source and operation drift fail verification.
- Public admission tests cover the 22 existing adapters, exact committed linkage,
  changed request parameters, enclosing caller transactions and both transfer
  authority losses. Existing request/response tests keep their assertions and now
  use valid recorded authority. They remain lower adapter proofs.
- Authenticated Strategy activation and production boot independently prove both
  first navigation and proven-absent navigation retry at different PostgreSQL
  backends. Linked `sent_or_unknown` evidence survives sender death after the game
  accepts the effect. All original orbit interruption/suppression proofs remain.
- Existing public Intent/family tests cover navigation, Cargo, deliveries,
  transfer, Intelligence, resources and module/refit outcomes. The Market fixture
  now balances its literal credits against its unchanged transaction quantities;
  assertions join succeeded attempts to root Intents and their Decision Episode.
- Public admission tests also pin the per-owner authority rules: authenticated
  Intervention dispatches with no active Revision, a Fleet Commitment without an
  active Revision cannot send, an Emergency Stop refuses before any Revision
  check, and a fenced Generation suppresses send with `not_sent` evidence instead
  of raising.

Jettison's existing low-level adapter is retained through recorded dispatch; no
new selectable root Intent was added. Ship/System scans, mount install/remove,
and repair remain explicitly unsupported (five generated operations). The
manifest covers all 27 Ship-owned operations without claiming whole-Fleet
capability reachability. Fleet-owned mutation owners remain separate.

### Migration verification receipt

Implementation base: `d069500` on top of main `dfd5691`. Commands qualify the
implementation working tree; the final implementation commit is the PR head.
All terminal logs are retained in `/tmp/opencode/505-adoption-*.log`.

| Command | Terminal result | Retained log |
| --- | --- | --- |
| `MIX_ENV=test mix compile --warnings-as-errors` | Pass, repeated during adoption. | `505-adoption-compile-2.log` through `505-adoption-compile-6.log` |
| `mix test test/integration/recorded_ship_dispatch_test.exs:279 --seed 0 --trace` before adoption | Exit 2; 16 tests, 1 failure, 15 excluded: navigation had no selected-attempt linkage. | `505-adoption-navigation-red.log` |
| Recorded navigation linkage after adoption | 16 tests, 0 failures, 15 excluded. | `505-adoption-navigation-green.log` |
| `mix test test/mix/tasks/verify_boundary_test.exs --seed 0 --trace` before source-check extension | Fails on undetected retired sends/caller attempt admission. The extended verifier passes in the later regression run. | `505-adoption-boundary-red.log` |
| `mix test test/spacetraders/api/error_test.exs --seed 0 --trace` before backpressure preservation | 13 tests, 1 failure: recorded 429 was not reported to the Governor. | `505-adoption-backpressure-red.log` |
| API errors, Market causal join and source boundary after fix, `--seed 0 --trace` | 21 tests, 0 failures. | `505-adoption-backpressure-green.log` |
| `mix space_traders.gen.models`; `mix space_traders.gen.operations` | Pass; 95 structs and operation inventory regenerated with no generated-content diff. | `505-adoption-codegen.log` |
| Public API client/errors/spec conformance, `--seed 0 --trace` | 47 tests, 0 failures. | `505-adoption-client-2.log` |
| Ledger, Generation, Contracts, Intelligence and source boundary, `--seed 0 --trace` | 50 tests, 0 failures. | `505-adoption-ledger-boundary.log` |
| `mix test test/spacetraders/api/recorded_dispatch_test.exs --seed 0 --trace` | 28 tests, 0 failures. | `505-adoption-public-admission.log` |
| `mix test test/integration/recorded_ship_dispatch_test.exs --seed 0 --trace` | 18 tests, 0 failures, including independent first/retry navigation and all orbit proofs. | `505-adoption-runtime-2.log` |
| Intelligence/Contract/Construction/Market/refit outcomes and autonomous scenario, `--seed 0 --trace` | 71 tests, 0 failures; 32.0 seconds. | `505-adoption-outcomes.log` |
| `mix test test/integration/runtime_baseline_proof.exs test/integration/ship_spending_admission_proof.exs --seed 0 --trace` | Exit 2; 2 tests, 1 failure; 5.5 seconds. Spending proof still fails at the 1,000-credit floor. This trading run buys/sells, reaches 175,800 credits and consumes 180 fuel; prior zero-trade runs remain retained. Trading remains unqualified, not net-profit-after-replenishment proof. | `505-adoption-opt-in.log` |
| `mix test test/integration/recorded_ship_dispatch_test.exs test/spacetraders/api/recorded_dispatch_test.exs test/spacetraders/api/client_test.exs test/spacetraders/api/error_test.exs test/spacetraders/api/spec_conformance_test.exs test/spacetraders/api/capacity_governor_test.exs test/spacetraders/mutation_attempts_test.exs test/spacetraders/fleet_intents_test.exs test/spacetraders/fleet_transfer_test.exs test/spacetraders/fleet_refit_test.exs test/spacetraders/manual_intervention_test.exs test/spacetraders/resource_acquisition_test.exs test/spacetraders/owned_intent_recovery_test.exs test/spacetraders/intelligence_acquisition_test.exs test/spacetraders/contract_execution_test.exs test/spacetraders/construction_execution_test.exs test/spacetraders/fleet_execution_test.exs test/integration/autonomous_runtime_scenario_test.exs test/spacetraders/contracts_test.exs test/spacetraders/intelligence_test.exs test/spacetraders/fleet_generation_test.exs test/mix/tasks/verify_boundary_test.exs --seed 0` | 247 tests, 0 failures; 61.3 seconds. | `505-postfix-focused.log` |
| `scripts/verify` | Exit 2; 753 tests, 1 failure; 134.7 seconds. The one failure is the pre-existing `resource_acquisition_test.exs:170` remote-resource discovery case, identical on untouched starting main. Formatting, warnings-as-errors, 95 generated models, operation inventory, API boundary and `/health` 200 pass. | `505-adoption-canonical-verify.log` |
| `mix test test/spacetraders/resource_acquisition_test.exs --seed 0` in isolation | 6 tests, 0 failures; 3.2 seconds. | `505-resource-isolated.log` |
| Focused regression run after the per-owner authority refactor, same file list and `--seed 0` | Exit 0; 250 tests, 0 failures; 61.1 seconds. | `505-final-focused-3.log` |
| `scripts/verify` on the final implementation tree | Exit 0; 756 tests, 0 failures; 135.3 seconds. Formatting, warnings-as-errors, 95 generated models, operation inventory, API boundary and `/health` 200 all pass. The previously noted `resource_acquisition_test.exs:170` failure did not reproduce. | `505-final-verify.log` |

Three defects were found and fixed while resolving the authority rules, each
visible before the fix and green afterwards: a fenced Generation raised inside
send admission instead of refusing (`505-gen-fix.log`, 63 tests), Intervention
attempts lost Revision provenance when the Fleet had one, and lost-Claim
preparation refusals did not supersede the preparing Intent.

The API fixture's first run failed on a nil-comparison query, not the protocol;
that fixture was corrected (`505-adoption-client.log`, then `client-2.log`).

Two review findings were fixed and re-verified at their public seams
(`505-review-findings-red.log`, then `505-review-findings-green.log`, 18 tests).
Recorded-dispatch preparation refusals now reach the existing blocker paths, and
protocol backpressure no longer makes supported work permanently infeasible.

During that fix, full-suite runs exposed a latent API Capacity defect: ordinary
demand admitted after a Retry-After window opened waited for a release timer that
was only armed if the queue was already non-empty at rejection time. Recorded
sends reach that state because their rejection is now reported to the Governor
without a transparent transport retry. Admission release is now armed whenever
ordinary demand is delayed, with a dedicated Governor regression. Reporting is
scoped to a still-authorized rejection, matching the previous signal semantics: our
own suppression is not a capacity signal. Evidence: `505-gen-alone-6.log`
(stalled, 8 tests), `505-gen-stack.log` (blocked in `CapacityGovernor.admit`),
`505-wedge-scope-2.log` (34 tests, 0 failures after the fix).

No production spending guarantee or whole-Fleet trading result is inferred from
the canonical suite or the successful opt-in trading example.

### Compatibility

No new schema migration or ledger is added. Existing historical attempts and
unknown unlinked actions are retained; no unknown send is fabricated or cleared.
New request evidence and transfer bindings use existing JSON fields and the #504
nullable linkage. Evidence-safe re-entry remains #506. #507 owns stopped/drained
cutover and concrete recovery qualification; this PR does not authorize production
operations or rollback to the retired unsafe send paths.
