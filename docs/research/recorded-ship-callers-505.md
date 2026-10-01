# Recorded Ship callers — #505

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

## Independent authority risk: spending admission

**Return #505 for clarification before expanding the migration.** The shared
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

This is the independent authority/interface-contract risk that #505 explicitly
requires returning before expansion. No caller-adoption implementation is
claimed. Current dispatch/recovery code, historical records, and protections
remain intact. #505's acceptance criteria remain unmet; no closing PR is warranted.

## Verification receipt

Production source qualified: `dfd5691b38dbec8d6a08b3da465d92bb05cf5cab` plus
the added report and opt-in proof. Every command sources `scripts/_toolchain.sh`.
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

## Review and return

`/code-review` reviewed the exact staged report/proof diff against starting main
once, using independent Standards and Spec reviewers. Standards found no
documented breaches or material smell findings. Spec found no findings: the
source-backed proof supports #505's explicit independent-risk return path; the
adoption criteria are deliberately unmet, with no false completion claim.

Commit these two evidence artifacts, return #505 to `needs-triage` with the precise
spending-admission question, and resume caller adoption after that contract is
resolved. The issue stays open. A PR claiming completion must wait for all
acceptance criteria, including a qualified shared spending-admission contract.
