# Shipyard-evidence repair: bounded proof receipt

**2026-10-23; #843. Evidence pinned at integration `6fe4c5c`; #838 follow-up `c43d34f` and the post-review corrections below are folded in. Overall acceptance: partial / inconclusive, not a whole-P1, Stage B, Gate 0 or live pass.** Normal acquisition and productive use are demonstrated in a finite application-boundary world. Conditional stressed payback is supported there; matched causal cash superiority is not. #838's short-horizon and funding criteria remain partial: its follow-up diagnosed the open-at-entry recovery but did not make R1 repeatable, and surfaced a productive-funding gap (below). Final code review done (findings fixed or declined in `5e5e687`); full gate at `5e5e687`: 1,948 tests, 0 failures, 7/7 PASS.

The [#821 frozen contract](https://github.com/bturney/spacetraders/issues/821#issuecomment-6316245751) and [approved payment amendment](https://github.com/bturney/spacetraders/issues/821#issuecomment-6355891158) control interpretation. This receipt records evidence, not a replacement spec, policy amendment or authorization. ADR 0011/0016, `ship-acquisition-v2`, the 48-hour cap, 0.5 no-history discount, unchanged presets, governed admission, one Allocation publication and MutationAttempts recovery remain authoritative.

## Provenance and reproducible inputs

Durable artifact root **D**: `/home/ben/.local/state/opencode/spec-821/`. Paths below are relative to D unless explicitly repository paths. Raw receipts remain outside Git: they contain large request/world histories and may include synthetic authentication material. Only accounting, identities, hashes and bounded conclusions are reproduced here; no credentials or raw world blobs are committed. D is a local evidence store, not a public download. A reader without it must regenerate receipts; unavailable evidence is not a pass.

| Evidence | Code / fixture pin | Surviving receipt / reproduction seam |
| --- | --- | --- |
| B, unchanged control | `accae0cced7a6d3e866724b0117ddaaaf66d6afc` | `837-final-B-{preset}/837-{preset}.json` and `-summary.json`; test-support-only overlay from `6236a75` |
| V, productive positive | `6236a75afb94977f9106b5d036f310f183d8e777` | `837-final-V-{preset}/837-{preset}.json` and `-summary.json`; `test/diagnostics/shipyard_productive_investment.exs` |
| Comparison correction | `392631e` | `837-final-compare-{preset}.json`; legitimate admission waits are not send-clock contradictions; no B clock patch |
| Earlier controls / real payment provenance | `1912c823a3d2a0237bd0ac4564cf0443529d8189` | `834-amended-{B,V}-{preset}/834-{preset}.json`, `834-safety-evidence/`; `834-result.md` |
| Acquisition / readiness | `b7b3243e2180d9b5be4c6b280e6d593c177565ba` | `836-readiness-evidence/836-{preset}.json`, `836-final-audit.json`; `836-result.md` |
| Lost purchase / repeated exposure | `2d1654c9a150fae631c90d57b3d6407534b13516` | `840-committed-evidence/840-{preset}.json`, `840-final-audit.json`; causal Outbox cleanup follow-up `f96156b`, `840-outbox-audit.json` |
| Deterioration / independent work | `68b94b5f3aa0fd5854d64751c7c7428a969e809b` | `841-final-68b94b5/841-{preset}-{before_buy,after_buy}.json`, `841-final-summary.json`; `841-result.md` |
| Payment / cutoff / unknown / reset | `2d75201e29d1a7a16e660d5591715d3b9d33e24e` | `842-committed-evidence/842-{payment,cutoff,missing-receipt,reset}-{preset}.json`, `842-final-audit.json`; `842-result.md` |

Here `{preset}` means independent `steady_growth` and `charted_expansion` runs, with immutable floors **50,000 / 75,000**. Historical receipts are not relabelled as latest-integration replays. The #837 raw `fixture_revision` literally says `uncommitted; use source hashes`: #843 independently checked all seven `comparison_sources` hashes in all four arms against Git blobs at `6236a75`; every hash matches. Preserve the original label and this hash verification, rather than inventing a committed label in the raw receipt. `837-progress.md` is stale and is not final evidence.

The common positive manifest is `821-finite-control-834-approved-payment-v3`: Agent **PROOF824**, `t0=2026-10-22T00:00:00Z`, announced reset **2026-10-27T00:00:00Z**, primary cutoff **2026-10-24T00:00:00Z**. Initial 400k credits, no monetary history, one empty 40-hold trader and one zero-cargo/fuel probe at A1; charted A1 `(0,0)`, A2 `(62,0)`, A3 `(0,62)`. Both routes have finite 1,600-unit source/demand caps, max40, buy/sell 1,000/1,500, price movement10/40, replenishment40/30min. One initially unobserved 100k light hauler, no replacement positive stock, observed modification fee2k, 10k preparation reserve. No seeded offer facts, winners, purchase Commitments, Attempts or Earnings.

One application/world clock drives normal 1,565-second/62-fuel legs, real return/refuel, one-second request service, normal governor/protocol waits and actual scheduled events. Fuel costs100 per100 units. No invented API credit fee. The approved amendment removes the exogenous 25k exposure / scheduled20k debit **only from the matched positive**. Existing selected-work protection50k, acquisition/preparation bound135k and independently priced productive envelope60k remain; worst-preset initial funding is **75k + 50k + 135k + 60k = 320k**, not345k. Reservations and overlapping Attempt exposure are counted once and reprice/release normally. The separate 20-unit real-owner payment case does not retroactively pass the original incompatible joint case.

| Final #837 arm | Generation / Revision | Host start → finish, 2026-10-23 UTC | Requests |
| --- | --- | --- | ---: |
| B steady | 3 / 3 | 12:54:25.612602 → 13:06:11.028054 | 2,693 |
| B expansion | 4 / 4 | 13:06:27.651587 → 13:18:17.090083 | 2,708 |
| V steady | 11 / 11 | 12:54:24.802093 → 13:24:45.150288 | 8,757 |
| V expansion | 12 / 12 | 13:25:55.006710 → 13:53:40.140687 | 8,962 |

These host times are run metadata, not economic effect times. B has **357 / 353** send-clock contradictions, V none in the corrected comparison. B completed8–9 cycles versus V's starter55; the large arithmetic Delta cannot be attributed to the new Ship. Identical inputs do not cure B's mixed wall/application-clock execution. Neither B production clocks nor policy were patched to manufacture comparability.

## Productive path, cash and forecast

The raw receipts retain selected/rejected Candidates, current Claim-only unmet work, Demands, original observations, Episodes, Commitments/Reservations, Intents, prepared-before-send Attempts/outcomes and authoritative request/effect history. `spending_checkpoints` joins actual send-time authority and protected funding. `all_demands`, `observations`, `decisions`, `all_commitments`, `intents` and `attempts` retain the need → claimed observation → offer evidence → admission → purchase → readiness → productive-use chain, including rejected/not-sent work. This is normal application execution, not a policy-only winner.

The #836 readiness receipts provide a compact earlier chain: Generation/Revision610/656 and611/657; observation Intent722/726, Commitment1006/1010; Market Episode1315/1321 → purchase Episode1316/1322. Offer observation00:26:34, durable send00:26:38, purchase effect00:26:39, authoritative readiness/registration00:26:40. Original purchase Attempts `9c3b00c9-46b0-43c1-a487-77420a3ab7c4` / `58808a89-63e2-463a-8b8f-7246e921f1ab` retain provenance. Acquired configuration matches the offer; registration itself grants **no execution Claim**. At send,419,900 credits less floor75k, selected50k, acquisition135k and productive60k leaves99,900. Actual preparation cost is0, not its10k reserve. Readiness-prefix cash is **−80,100**, trough319,900; this is not productive-use proof by itself.

In final #837 V, effective purchase Attempts are `c7682db6-878e-41a9-8779-f67617b0ffda` / `fb135839-d47c-4f55-9b43-f4d6c10ffdea`; earlier not-sent Attempts remain visible. Both new Ships complete **52 strictly profitable cycles**. Their summed operating Net Earnings are **1,027,400 / 1,027,000**. This verifies productive contribution; it does not establish causal whole-policy superiority. For example, steady's first two new-Ship cycles have expected19,938/19,476 and actual20,000/19,800, finish02:41:46/03:34:21, and include a real return/refuel before repetition. Complete-cycle evidence, not a profitable first outbound leg alone, underpins the forecast.

| Final #837 account at T | B steady | B expansion | V steady | V expansion |
| --- | ---: | ---: | ---: | ---: |
| Actual sale receipts | 540,000 | 480,000 | 6,414,000 | 6,415,200 |
| Goods outlays | 400,000 | 360,000 | 4,321,200 | 4,321,600 |
| Fuel outlays | 1,700 | 1,500 | 21,300 | 21,300 |
| Acquisition / actual preparation | 0 / 0 | 0 / 0 | 100,000 / 0 | 100,000 / 0 |
| **N(T), all actual outlays included** | **138,300** | **118,500** | **1,971,500** | **1,972,300** |
| End credits / observed trough | 538,300 / 360,000 | 518,500 / 360,000 | 2,371,500 / 279,400 | 2,372,300 / 279,400 |
| Completed operating Earnings | 178,400 | 158,600 | 2,111,900 | 2,112,800 |
| Starter / new-Ship completed cycles | 9 / 0 | 8 / 0 | 55 / 52 | 55 / 52 |

Arithmetic Delta is **+1,833,200 / +1,853,800**, **causal attribution inconclusive**. There is no10k/5% superiority gate. No asset resale, released-exposure income or second opportunity-cost deduction is added. B retains40 unsold units/basis40k on the starter; V retains40/basis40k on the new Ship (IRON steady, COPPER expansion). All route source/demand stocks are1,600 at T. All traders retain38/100 fuel; probe0/0. V retains three unfinished Intents, open transit, zero unsettled Attempts, zero unknown monetary effects and no closure-tail effects. B's blocked/unfinished work stays in its raw receipt. Unexplained cash is0 in these complete accounts, not a rule for missing effects elsewhere.

**Conditional future payback, not realized repayment:** incumbent admission records `minimum_planned_realized`, enabled rate27,235.3389/hour, exposure135k and horizon172,800s. Independent complete-cycle achievable rate18,028/hour is lower and controls the stress check. With **50% lower repeat throughput, 25% higher future operating costs and +1h lead**, both summaries report20 cycles,6,311s stressed complete-cycle duration,3,606s lead,129,826s completion,5,250 stressed profit/cycle,1,160,000 future receipts against1,055,000 future outlays and100k acquisition: **5,000 capital-loaded surplus**. Required funded capital65,938; obtainable units1,040. Shared finite-demand check assumes the incumbent repeats on the same route at its fastest observed period; funding, finite demand, cap/reset checks pass **under these fixture assumptions**. Actual positive cash above is separate from this forecast. Low enabled rate, near reset, nonpositive stressed cycles, unfunded inputs or unsustainable shared demand invalidate/support only inconclusive forecasts; existing `shipyard_payback_test.exs` retains those counterexamples.

## Outcome matrix

Each column covers the unchanged preset independently. “Bounded pass” means the named demonstrated seam only, not all issue criteria, merged-code qualification or a gate certificate.

| Case | steady_growth | charted_expansion | Evidence / remaining limit |
| --- | --- | --- | --- |
| **P1 positive** | Productive path pass; overall partial | Productive path pass; overall partial | #836 readiness + #83752 cycles and conditional stressed forecast. B comparison inconclusive; full safety matrix/latest integrated gate not complete. Do not promote classifier string `attributed_productive_acquisition` into whole-P1 approval. |
| **P2 need/liveness** | Bounded pass | Bounded pass | #832/#836 `shipyard_evidence_demand_test.exs`: no need → no acquisition polling; real unmet work with unrelated Market gaps → claimed observation, retained unrelated authority; review follow-up: an unsettled purchase also raises no acquisition-driven Shipyard polling (`market_domain_allocation_test.exs`). Use committed tests; no invented missing historical #832 receipt. |
| **R1 short horizon** | **Partial** | **Partial** | #838 follow-up `c43d34f`: R1 is **partial / inconclusive** as a repeatable application proof. Safety and the executing alternative hold; an actual capped valuation refusal (`enabled_value_not_above_cost`) occurs in some exact runs but other runs end at `no_claim_only_loser`, because replacement Market evidence cannot revalidate the original loser. Missing eligible work is not accepted as a valuation pass; set `SHIPYARD_PROOF_REQUIRE_R1=true` to demand the exact evidence (it fails when absent). Known-short-horizon valuation is covered by the `market_domain_allocation_test.exs` value-refusal case and #840's later second-offer refusal (the same file's `horizon` scenario is the **unknown**-horizon case, not this). Possibility is shown; deterministic reachability is not. |
| **R2 capital200k** | **Partial** | **Partial / funding refusal observed** | `838-R2-{B,V}-{preset}/`; B also refuses, not an improvement. Steady V's `acquisition_already_unsettled` with no sent purchase is **diagnosed** (#838 `c43d34f`): a prepared purchase whose enabled-work support expired at the same instant became `not_sent`; `Acquisition.reconcile` snapshots open-at-entry, withdraws it locally (no HTTP, original Attempt and provenance kept) and refuses a second investment at that one boundary; the next boundary is clear. Not a transport ambiguity and no production bug shown. The eligible-boundary funding refusal (219,900 credits, 50k selected-work protection, 119,900/94,900 surplus below 135k exposure) passes when naturally reached under both presets, but the exact steady path does not reach it repeatably: **partial**. A not-sent recovery refusal is inconclusive for funding, not an alternate pass (`SHIPYARD_PROOF_REQUIRE_R2=true` enforces this). No Closes#838 until criteria met. |
| **R3 deteriorated/contested** | Bounded pass | Bounded pass | `shipyard_refusal_test.exs`: executable depletion/replenishment and separately unprofitable sell1,000; no purchase, explicit economics/no eligible work, independent good continues. Not refusal based on competitor identity. |
| **S1 freshness/presence/reset evidence** | Bounded pass | Bounded pass | #835`77aa9eb` focused guards plus the [audited pinned #837 departure/return trace](shipyard-s1-audit-821.md): legitimate unrelated probe Market work → normal return → new original offer/Market evidence → current Claim-only loser → purchase with actual docked presence. 301s expiry/refresh and reset fallback remain covered separately. This representative integration proof does not isolate absence as the only refusal cause or qualify every concurrent schedule. |
| **S2 interruption** | Bounded pass | Bounded pass | #839`9474650` persisted claimed observation resumes same authority; #840 lost purchase response, real recovery/readiness, one debit/registration, original ambiguous→accepted Attempt. **Owned runtime restart, not whole BEAM or database restart.** |
| **S3 deterioration/independence** | Bounded pass, limited scope | Bounded pass, limited scope | #841 four opt-in cases; same unrelated Claim/Intent survives through actual profitable action, normal1request/2game-seconds. Before-buy means **next buy after the current trade**, not first lifetime buy. After-buy clears sunk goods at zero operating Earnings, not an invented positive outcome/strict goods loss. Not a full lifecycle or matched48h comparison. |
| **S4 exposure/cash/reset** | Bounded safety pass; missing-money claim inconclusive | Bounded safety pass; missing-money claim inconclusive | #840 second offer while unsettled refused, later genuinely poor horizon refused; #842 four independent safety variants below. Unknown amount/time remains unknown. No Cartesian simultaneous-fault or whole-Generation replacement proof. |

The integration contains the11 code leaves; that count establishes neither acceptance nor P1. #827/#828/#830 remain optional adjacent reliability work, not fabricated Stage B blockers or claimed resolutions. Earlier isolated passes/retries do not meet their original acceptance criteria or establish three consecutive full gates.

## Safety accounting and authority

**#840:** both presets retain one effective100k purchase and original Attempt/provenance across owned ShipServer/DemandScheduler stop and production boot. A tied *pre-send* Fleet read once falsely proved absence; `2d1654c` requires a governed replacement rather than using that ambiguous retained source. Effective send02:15:24, effect02:15:25, original Attempt accepted02:15:28, readiness02:15:29. Generation/Revision486/499 and487/500. Second offer remains obtainable but cannot create another unresolved acquisition; later normal30-minute valuation13,602.54 loses to135k exposure. Prefix N=**−40,500**, trough359,500, not positive investment payback. The same original selected-work Claim/Reservation survives. `f96156b` fixes only causal fixture Outbox cleanup; unrelated rows remain.

**#841:** retained independent action earns19,800 in every arm, same authority at send/effect. Gen/Revision13/13 steady-before,14/14 steady-after,15/15 expansion-before,16/16 expansion-after. Respective actual prefix N values **+78,000 / −100,500 / −40,400 / −100,500**, troughs279,400 /239,800 /239,800 /239,800. Stop times04:55:23 /01:20:29 /01:20:13 /01:20:29 differ: these are **not matched comparisons**. Actual cash/stock/unknown and request histories stay in `841-final-summary.json` and raw receipts. All four heavy cases moved to `test/diagnostics/shipyard_thesis_deterioration.exs`; the ordinary Intent guard tracer remains. **No180,000ms timeout override retained.** Some explanatory refusal timestamps are host time; use request/effect and changed-observation times for game ordering.

| #842 separate variant, both presets | Application evidence and account |
| --- | --- |
| **Real-owner payment** | Normal depth20 buys20×1,000: same Commitment Reservation/Attempt exposure25k, not two disjoint liabilities. Send00:00:05, actual effect00:00:06, ambiguous original Attempt; unknown amount interval[−25k,0], amount/time nil. Owned runtime restart plus real Ship/Agent evidence accepts original Attempt00:01:08; repeated boot yields one20k debit. Prefix00:01:11: N−20k, trough/end380k, Cargo20/basis20k, fuel38. Re-reading original cutoff after recovery gives[−20k,0] with `effect_at=nil`, not a fabricated timestamp. Generation/Revision181/133 and185/137; original Attempts `52a79640-2efa-4686-9324-e78dca38c488` / `1291ce8b-ec85-4284-9a91-79be1b61627f`. No fabricated +1h occurrence. |
| **Pre-T buy, post-T sale** | Separate first-cycle T00:26:13, not48h:40k buy is pre-T;60k sale00:26:19 is closure tail. T N−40k, credits360k, Cargo40/basis40k, fuel38, open Sell; tail20k operating Earnings never moved into T. Generation/Revision182/134 and186/138. |
| **Missing decisive receipt** | Real40k buy, hidden oracle sale60k00:26:19; application Sell Attempt remains ambiguous/fenced with no Earnings. Known goods cost−40k; net amount nil, interval[−40k, unbounded/unknown], sale amount/time unknown. Selection quote1,500 is **not** a hard unseen-receipt maximum. Hidden oracle+20k cannot certify application profit/payback. Generation/Revision183/135 and187/139. |
| **Announced reset / queued old sale** | Governed reset00:00:30; actual buy/navigation precede it, original Sell continuation00:26:15 remains queued. Definitive API mismatch lets lifecycle owner fence original Generation/Revision184/136 and188/140. Drive original wake to00:26:16: no extra HTTP/Sell Attempt/post-reset benefit; original buy history remains, N−40k, Cargo40/basis40k/fuel38. Host-time `fenced_at` is not effect occurrence. Replacement minting/whole DB restart are unproven here. |

`oracle_account` is hidden controlled-world truth. Application `details.available_evidence` and `unknown` retain uncertainty. API transaction occurrence timestamps, not completion/recovery timestamps, score cash at cutoff. Missing decisive facts are never zero. Acquisition/support accounting remains distinct from the bounded goods evidence tracer; neither a new ledger nor recovery owner was added.

## Productive-funding counterexample (#838, reported, not repaired)

Precommit receipt `838-real-presets/838-R2-steady_growth.json` (code `6fe4c5c` plus uncommitted test-driver changes, not exact-pin evidence at `c43d34f`) preserves a genuine purchase sent 01:22:38 and effected 01:22:39 after two 60k sales. Credits at send were 239,700; the normal floor (50k) plus selected-work protection (50k) leave 139,700; the 135k acquisition exposure leaves **4,700**, below the separate 60k first-cycle productive envelope. The actual 100k debit leaves 139,700; later independent spending takes the trough to 99,600, still above the floor, so no floor violation or future-sale anticipation is claimed. **The stronger productive-envelope requirement is not protected by the surplus-only acquisition check in this trace.** The exact committed steady replay instead hits the not-sent expiry, so this purchase is not reproduced there. No policy change is made here; the gap is surfaced for the owner of funding policy (ADR 0016, the floors and the 48-hour cap are untouched).

## Adjacent production corrections

The leaves are not evidence-only. These production changes landed beside the proof and apply beyond Shipyard acquisition:

| Change | Why necessary | Scope of effect |
| --- | --- | --- |
| #841 `e489d48` `destination_spread_lost` buy guard (`Fleet.Intents`) | The before-buy S3 arm bought on a pre-change destination quote after newer evidence had removed the spread. | **Every Market-trade buy**: refused as infeasible, nothing sent, Allocation replans. Contract and construction deliveries unchanged. |
| #836 `b7b3243` fuel Market dependency on every trade candidate (`FleetPlanning`) | Independently known FUEL pricing must keep its original Market dependency when an owned-Ship rate is unknown. | **Every Market trade candidate** now lists the fuel Market among its dependencies, so a stale fuel quote invalidates the trade. |
| #836 `b7b3243` `FleetAcquisition.current_investment_evidence` pre-send gate | Revalidates the published investment's validity and Market evidence at the MutationAttempt send checkpoint rather than restamping an old loser. | Every ship-purchase send. It is the cause of the `not_sent` expiries in the R2 history above. |
| #833 `CreditSpending` post-effect balance (`cf0f156`) | Same-tick confirmed purchase and balance made the refit guard double-count 40,000 exposure and refuse a legal installation. | Only an exact Agent, Generation, operation and Attempt match; all other exposure stays protected. |
| #833 `mutation_attempts.sequence` migration (`4a1a721`, `2e8ab0a`) | Same-tick Attempts ordered by random UUID could pick a rejected registration or order a purchase after its install. | Tie-breaker only for registration, recovery and history reads; additive column, backfill keeps prior order. |
| #833 `Clock.timestamp` in Intent / MutationAttempt | Authority and recovery must read the one application clock, not wall time, so the finite World is coherent (B's wall-clock stamping is the mixed-clock caveat). | Intent `finished_at` and MutationAttempt recorded/sent/updated times; wall time unchanged in production where no test clock is configured. |

## Validation and replay

**#843 executed at `6fe4c5c`:** existing read-only #834/#836/#840/#842 auditors passed (four controls, two readiness, two purchase recovery, eight cutoff/safety receipts); log `843-validator.log`. The inline raw validator below passed all four #837 arms (`843-raw-audit.log`), independently checking cash chains, original fixture hashes and 52 new-Ship cycle/sale records per V arm. Existing payback regressions: **14 tests, 0 failures, seed 0, 0.1s**, `843-payback-test.log`, checkout-local DB/config and `_build`, no DATABASE_URL override. Both historical summary comparisons recomputed using the existing committed classifier: `843-compare-{preset}.json`; productive path pass, conditional payback supported, Delta attribution inconclusive. These checks do not replay 48h or certify latest runtime behavior.

Prior scoped evidence: #841 final ordinary28/0 (105.9s), merger after#84128/0; #842 exact-pin154/0 (120.7s), merger after#84240/0. **Last completed full gate is `a35a12a`:1,937 tests,0 failures,7/7 PASS,595s, before#841/#842.** Its original output is `/tmp/claude-1000/-home-ben-src-spacetraders--claude-worktrees-bridge-cse-012P8rxNSSnevu47tLzMFXTc/6bf70877-1e36-5607-9724-1619950c250a/tasks/bzl63vvwk.output`, reported in durable `STOCKTAKE.md`. This is historical, not a latest green badge. **Final integrated gate at `5e5e687` (after all leaves, #838/#843 follow-ups and review fixes): `scripts/verify` 7/7 PASS, 1,948 tests, 0 failures, 574s.** Earlier full runs on this branch failed once each on known intermittents (#818 stray Postgrex output at `f96156b`; #828 commitment-id order at `895b7ea`; a ShipServers-left-running probe in `ShipyardProductiveInvestmentTest` during review-fix verification); these are not declared fixed. Prior #837 timeout/Glance failures under concurrency remain historical observations, not declared fixed by retries.

1. **Recheck stored receipts without runtime/DB access.** In Python, import `834-audit.py` and call `audit(path)` on each `834-amended-*/834-*.json`; import `836-audit.py` and call `audit(preset)` for both presets. Avoid their main blocks if preserving the stored summary files. Then run:

   ```sh
   python3 /home/ben/.local/state/opencode/spec-821/840-audit.py
   python3 /home/ben/.local/state/opencode/spec-821/842-audit.py
   ```

2. **Recompute summary classification / focused regressions**, in this repo with dependencies available; no live API or full replay:

   ```sh
   mix test test/spacetraders/shipyard_payback_test.exs --seed 0 --max-failures 1
   MIX_ENV=test mix run --no-start test/diagnostics/shipyard_productive_compare.exs /home/ben/.local/state/opencode/spec-821/837-final-B-steady_growth/837-steady_growth-summary.json /home/ben/.local/state/opencode/spec-821/837-final-V-steady_growth/837-steady_growth-summary.json
   MIX_ENV=test mix run --no-start test/diagnostics/shipyard_productive_compare.exs /home/ben/.local/state/opencode/spec-821/837-final-B-charted_expansion/837-charted_expansion-summary.json /home/ben/.local/state/opencode/spec-821/837-final-V-charted_expansion/837-charted_expansion-summary.json
   ```

3. **Regenerate historical positive arms only if needed.** Use separate owned checkouts/DBs at B and V pins, leave DATABASE_URL unset, create/migrate each checkout's DB. Overlay **only** the seven paths in raw `comparison_sources` from `6236a75` onto B (no production/config/schema patch). Set `SHIPYARD_PROOF_PRESET` to each preset and `SHIPYARD_PROOF_RECEIPTS` to a fresh output directory; run `MIX_ENV=test mix run --no-start test/diagnostics/shipyard_productive_investment.exs`. For corrected historical comparison, use `392631e`'s comparator/payback classifier on the summaries; recorded fixture sources stay unchanged. Record new source hashes, IDs, host/game clocks and outputs; never overwrite historical receipts. B's clock-dependent numbers need not repeat.

4. **Replay bounded safety cases only on an owned idle DB.** At the listed code pins, #836 uses `mix test test/spacetraders/shipyard_purchase_path_test.exs test/spacetraders/shipyard_evidence_demand_test.exs --seed 0 --max-failures 1`; #840 uses `mix test test/spacetraders/shipyard_purchase_recovery_test.exs --seed 0 --max-failures 1`; #842 uses `mix test test/spacetraders/shipyard_cash_cutoff_test.exs test/spacetraders/shipyard_payback_test.exs --seed 0 --max-failures 1`. Set `SHIPYARD_PROOF_FIXTURE_REVISION` to the full actual HEAD and receipts to a fresh directory. #841 runs all four preset/arm combinations with `MIX_ENV=test SHIPYARD_PROOF_PRESET=... SHIPYARD_PROOF_ARM=... SHIPYARD_PROOF_RECEIPTS=... mix run --no-start test/diagnostics/shipyard_thesis_deterioration.exs`. Preserve output/status; no `--trace`/timeout override as ordinary-budget proof.

All runtime proof owners require synchronous clock/governor isolation, real event-bounded waits, original configuration restoration, owned ShipServer/DemandScheduler quiescence and FixtureLeakProbe. Restart means dead old owned PIDs and production reconstruction from committed state, not manual completion. No blanket cleanup, muted unexpected requests/output, invented capacity-proceed result, extra scheduler or timeout inflation. Read-only receipt audits do not start an alternative runtime owner.

The following additional read-only validator independently recomputes #837 raw cash, positive cycle arithmetic/sale evidence, identity and fixture-source provenance. Run from the repository; no API, DB or runtime owner starts. It supplements, not replaces, the incumbent complete-cycle payback classifier:

```sh
python3 - <<'PY'
import hashlib, json, pathlib, subprocess
root = pathlib.Path('/home/ben/.local/state/opencode/spec-821')
for arm in ('B', 'V'):
    for preset in ('steady_growth', 'charted_expansion'):
        base = root / f'837-final-{arm}-{preset}'
        raw = json.loads((base / f'837-{preset}.json').read_text())
        summary = json.loads((base / f'837-{preset}-summary.json').read_text())
        assert raw['as_of'] == summary['as_of'] == '2026-10-24T00:00:00Z'
        assert raw['manifest'] == summary['manifest']
        assert raw['floor'] == {'steady_growth': 50000, 'charted_expansion': 75000}[preset]
        for path, expected in raw['comparison_sources'].items():
            blob = subprocess.check_output(['git', 'show', f'6236a75:{path}'])
            assert hashlib.sha256(blob).hexdigest() == expected
        cash, trough, sales = 400000, 400000, {}
        for effect in raw['request_effects']:
            assert effect['completed_at'] <= raw['as_of']
            assert effect['before']['credits'] == cash
            response = effect.get('response')
            tx = response.get('transaction') if isinstance(response, dict) else None
            if tx:
                if effect['path'] == '/v2/my/ships':
                    assert tx['price'] == -effect['signed_cash'] == 100000
                else:
                    assert tx['totalPrice'] == abs(effect['signed_cash'])
                    assert tx['units'] * tx['pricePerUnit'] == tx['totalPrice']
            cash += effect['signed_cash']
            assert effect['after']['credits'] == cash
            trough = min(trough, cash)
            if tx and effect['path'].endswith('/sell'):
                sales[(tx['shipSymbol'], tx['timestamp'])] = tx['totalPrice']
        assert cash == summary['account']['credits']
        assert cash - 400000 == summary['net_cash']
        assert trough == summary['account']['low_credits']
        cycles = [e for e in raw['earnings'] if e['ship_symbol'] == 'PROOF824-3']
        for e in cycles:
            assert e['net_earnings'] == e['revenue'] - sum(e[k] for k in ('goods_cost', 'fuel_cost', 'other_cost'))
            assert e['net_earnings'] > 0
            assert sales[(e['ship_symbol'], e['finished_at'])] == e['revenue']
        assert len(cycles) == (52 if arm == 'V' else 0)
        assert [e['net_earnings'] for e in cycles] == summary['new_ship_cycles']
        print(arm, preset, 'PASS', raw['generation'], raw['strategy_revision'], cash, len(cycles))
PY
```

### Critical artifact integrity

SHA256 values below pin the actual surviving files, not reconstructed receipts. The raw and summary pairing is essential: summaries alone do not preserve authority/request history.

| D-relative artifact | SHA256 |
| --- | --- |
| `837-final-B-steady_growth/837-steady_growth.json` | `736a3c655cd304eaba7f682de38a1d0bf2660dddb2d898c12fa02446ff70e32d` |
| `837-final-B-steady_growth/837-steady_growth-summary.json` | `cfe58eedd49a366638075e14c63de2e84386244c033130fbbc0a52af1348fd8f` |
| `837-final-B-charted_expansion/837-charted_expansion.json` | `50129adc79fc02f728fbe6012d4067c5841277bb6836e4062dcbed9c8da743fb` |
| `837-final-B-charted_expansion/837-charted_expansion-summary.json` | `16bf39aa4c4bd67be61a94b096f16ec13dd64f2229ca4fe2473d403eca783729` |
| `837-final-V-steady_growth/837-steady_growth.json` | `c211deea368af9a2ec6e06ad880f1bc8bd359454526d194cefee7f035241a4ad` |
| `837-final-V-steady_growth/837-steady_growth-summary.json` | `c2fe8987105b6bbaad90af302f887500754abde760654503b9bc15306566fce3` |
| `837-final-V-charted_expansion/837-charted_expansion.json` | `2273dc3e35c70695cd393e4b7a01e490fba64fdfc5a517dc2171efbb4ac25870` |
| `837-final-V-charted_expansion/837-charted_expansion-summary.json` | `7ee51897022afd566b2407ecaf8dbf4f1074f26b37e2461ddbbf55dcc616c1f1` |
| `836-final-audit.json` | `7b6f1f47b7b3f5a4d619e6e083f147c99412a3eec2553f54f061e99341aa71b9` |
| `840-final-audit.json` | `85ebed860db257df3cf720f49e032d72f77369043725c6ea468d65b08db8ca78` |
| `841-final-summary.json` | `5f84559639c9b561b40f91634a032a44b70998b644b262e4d5dcc3bdb5a49365` |
| `842-final-audit.json` | `11d67bee3add7c18e1d5308cc33de296613402a0dc376f1497da7a46de6e8eff` |
| `834-audit.py` | `73dac9decb0d9407748d8ebd964d56e3c6e4463a9ae8942554623e6f7b5fc9c9` |
| `836-audit.py` | `6b6f90fd55b40a90c20501b2c9b3af47f0a44fde5732e2b4a6b9572b44210505` |
| `840-audit.py` | `0d23333d0a6d9fbb71a0f94843677d9b45a4f1a279d985bc81f0ddc35b33a3b7` |
| `842-audit.py` | `224923addf5abe74083cb1917d14917c209021a63367740b06d9df0ebbfbcc23` |

Historical #832/#835/#839 behavior remains reproducible from committed tests (`shipyard_evidence_demand_test.exs`, `shipyard_observation_recovery_test.exs`), not a fabricated vanished receipt. Baseline `accae0c` is the merge of deployment PR#831, **not** an additional Shipyard-proof leaf or acceptance result.

## Remaining frontier

Stage A research/diagnosis is complete: [#824 combined findings](https://github.com/bturney/spacetraders/issues/824#issuecomment-6297301408) and [#739 diagnosis](https://github.com/bturney/spacetraders/issues/739#issuecomment-6296475698) selected this bounded evidence-path repair rather than allocator replacement. Stage B has delivered local code and substantial deterministic evidence, **not complete frozen acceptance or qualified gameplay**. The [S1 follow-up](shipyard-s1-audit-821.md) establishes the representative return/progress obligation from surviving receipts without a new run. Parent must incorporate #838's final root proof when delivered, then record the latest unchanged full gate and final review; this receipt intentionally does not close/amend#821 or#838.

Next outcome is trustworthy current-build productive growth and refusal qualification on Gate0, not Gate1 advancement or more investment categories. Strategy simplification/economic-default work, cross-horizon valuation, probes/mining/contracts/supply-chain investment and simulator fidelity remain separate proposals/deferrals. #814's Scouting UI correction is already on main (`f935144`, issue closed2026-10-22); it is not deferred economic-intelligence valuation. #815 class/role persistence remains deferred. No live gameplay, production deployment, Strategy changes or simulator qualification was authorized/performed by this receipt.
