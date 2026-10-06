# Autonomous-runtime contract and proof baseline — #503

## Decision for Operator review

**Recover loss-safe Ship dispatch first, behind Evidence/API admission, with
`MutationAttempts` as the sole recovery authority.** A production boot retry
sent a real controlled-game request from inside an enclosing PostgreSQL
transaction. An independent connection could see neither its prepared nor its
sent-or-unknown retry; killing the sender lost both while the game retained the
effect. This is a reproduced C04 violation, not a transaction hypothesis.

The favorable trading qualification is **inconsistent**. A retained run discovers
the profitable A1/A2 pair and survives restart, then continues to A3 with **zero
purchases/sales**, 175,000 credits and 80 fuel. The latest reviewed run instead
buys/sells 40 units, reaches **175,800 credits**, and leaves A3's demand open.
Both render **“Outcome status unknown.”** Both results are retained; the latest
success does not erase the earlier failure or prove stable autonomy. Callback
ordering, API-capacity history and timing remain causal hypotheses. No production
planning fix was attempted in this baseline.

This is the bounded baseline requested by
[#503](https://github.com/bturney/spacetraders/issues/503), under
[#502](https://github.com/bturney/spacetraders/issues/502). Recovery implementation
and the next executable issue require Operator review. #503 remains open until
review and representation of the next accepted work.

## 1. Inspected fixed point and source decisions

| Item | Retained context |
| --- | --- |
| Production code inspected and executed | `00a43d8fd47793bc2dc0555d806b678b870d25a6` |
| Freshness check | `git fetch origin main`; `git merge-base --is-ancestor origin/main HEAD` failed on the initial clean, behind-main checkout. Created `feature/503-runtime-baseline` from freshly fetched `origin/main`; its HEAD was the revision above. |
| Changes for this investigation | `ScenarioCase` committed-connection option; `TestClock` next-live-wake inspection; stateful game fixture; explicit runtime qualification file; this evidence report. Production runtime code remains the inspected revision. |
| Evidence date/environment | 2026-10-01 UTC; Linux; Erlang/OTP 27 / ERTS 15.2.7, Mix/Elixir 1.18.4; PostgreSQL 17.10; real PID-partitioned test databases; controlled Req transport; one shared controllable game clock. |
| Tracker authority | #502 replacement contracts; #503 accepted proof seam. Administrative supersession of the old leaves is not evidence of implementation. |

Read source decisions through the completed
[map #297](https://github.com/bturney/spacetraders/issues/297), especially
[Strategy #301](https://github.com/bturney/spacetraders/issues/301),
[authority/recovery #304](https://github.com/bturney/spacetraders/issues/304),
[observation/capacity #303](https://github.com/bturney/spacetraders/issues/303),
[allocation #307](https://github.com/bturney/spacetraders/issues/307), and
[architecture #309](https://github.com/bturney/spacetraders/issues/309).
[Coverage #482](https://github.com/bturney/spacetraders/issues/482) includes every
discovered System, not just Headquarters. [Neutral Wait #487](https://github.com/bturney/spacetraders/issues/487)
and [ADR 0012](../adr/0012-neutral-wait-contract.md) retain their strict mint and
equivalence rules. ADRs [0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md),
[0010](../adr/0010-autonomous-runtime.md), and
[0011](../adr/0011-single-recovery-authority-for-mutations.md) remain governing.

The attached [structural reconnaissance](https://github.com/bturney/spacetraders/issues/502#issuecomment-5922821570)
was inspected against this fresh revision. Its prior checkout, production
reports, and proposed explanations are not substituted for these new results.
The [supersession register](https://github.com/bturney/spacetraders/issues/502#issuecomment-5922821633)
preserves the inherited evidence and separate tooling work.

## 2. Commands and terminal results

Every shell used the pinned toolchain. No live-game or production-host
commands were used. The canonical gate uses the alias in `mix.exs`; it is not
replaced by a subset of tests.

| Run | Command | Terminal result |
| --- | --- | --- |
| Fresh-main baseline | `scripts/verify` | **Exit 0**; 702 tests, 0 failures; seed 707344; 126.9 seconds; 95 generated model files current; operation inventory current; gameplay boundary intact; `/health` 200. No skipped tests reported. |
| Compilation during fixture development | `MIX_ENV=test mix compile --warnings-as-errors` | **Exit 0** after each support-code change. The repo has no separate configured static typechecker. |
| Runtime qualification | `mix test test/integration/runtime_baseline_proof.exs --seed 0 --trace` | **Exit 2**; 2 tests, 2 failures; 4.6 seconds. Trading and independent dispatch durability fail. No skip tags. |
| Post-review targeted check | `mix test test/integration/runtime_baseline_proof.exs test/spacetraders/outbox_test.exs --seed 0 --trace` | **Exit 2**; 4 tests, 1 failure; 4.0 seconds. Both outbox cases and R1 pass; C04 still fails with a pinned independent observer. This is another inconsistent R1 result, not an all-contract pass. |
| Existing scenario regression | `mix test test/integration/autonomous_runtime_scenario_test.exs --seed 0` | **Exit 0**; 1 test, 0 failures; 0.8 seconds. |
| Final canonical verification | `scripts/verify` | **Exit 0**; 702 tests, 0 failures; seed 80597; 124.3 seconds; generated models/inventory current; boundary intact; `/health` 200. No skipped tests reported. |

[Complete terminal evidence](https://gist.github.com/bturney/e588032ca5864e94b58edd260e161a22)
retains the fresh baseline, final gate, qualification, single-file regression,
and inconsistent/invalid clock-driver experiments. `503-qualification-final.log`
records the two-failure qualification before review; `503-reviewed-proofs.log`
records the post-review targeted run; `503-final-gate.log` is the canonical gate.
The canonical gate was repeated after shared clock support changed, not to hide
a failure. The
qualification file intentionally has an explicit `_proof.exs` name: ordinary
`mix test` discovers `_test.exs` files, so a green canonical suite does **not**
claim that these additional recovery obligations pass. Run the qualification
command separately; its failing assertion remains a real failing contract,
rather than a characterization test that asserts broken dispatch is correct.

The initial fixture experiment was invalid because Req allowances were installed
before the stub, and its artificial page limit did not match the requested limit.
Those runs were discarded. The retained run installs dynamic allowances after
the stub, honors requested pagination, and synchronizes already-delivered
production work before advancing to registered production clock wakes. Fixed
fast-forward ticks produced inconsistent trading results; an arrivals-only driver
failed to advance demand-scheduler backoff. Neither experiment is qualified as a
stable pass. The final driver includes scheduler wakes and ignores dead timer
destinations. Synchronization sends system inspection messages; it never sends a
reconciliation wake or selects work. The doubtful assumption was that one passing
fast-forward run established a reliable productive loop.

Baseline warnings about unused test bindings and Postgrex disconnect messages
are retained in the log. They did not fail the gate. No verification-tooling
blocker was encountered. If a subsequent run loses its terminal result or hits
sandbox/partition teardown failures, preserve that result and use
[#400](https://github.com/bturney/spacetraders/issues/400),
[#399](https://github.com/bturney/spacetraders/issues/399), and
[#401](https://github.com/bturney/spacetraders/issues/401); do not relabel it green.

## 3. Actual owners, commits, and wakeups

```text
Authenticated /setup -> /agents/new -> FleetGeneration.mint
Authenticated /strategy -> FleetStrategy.activate
                                     |
                   Generation revision + intelligence announcement
                                     |
                     FleetAllocation.Reconciler (production)
                         | waypoint / demand / boot wake
                         v
         Intelligence -> Resources -> Contracts -> Construction -> Acquisition -> Refit
               |              capability-local selection/publication
               v
       FleetAllocation.publish_portfolio -> Episode + Claims/Reservations/Pledges + outbox
               |
        claimed root Intent -> Evidence reads / API capacity -> mutation ledger -> transport
               ^                                              |
               |                  response / ambiguity --------+
         durable Timeline due_at -> ShipServer -> authoritative Ship -> Intent reconcile
```

### Whole-Fleet reconciliation (C01/C02/C03/C05/C06/C12)

| Boundary / owner | What the current code actually does | Commit / wake / gap |
| --- | --- | --- |
| `FleetStrategy.activate/2`, `FleetGeneration.activate_strategy/2` | Snapshots an Operator draft, installs the revision on current Generations, withdraws superseded demands, announces Intelligence work. | Revision writes are transactional; Generation installation and announcements follow. The new proof uses the authenticated LiveViews with the coordinator already running. Atomicity across the entire activation sequence is unproven. |
| `FleetAllocation.Reconciler` | Waypoint wake calls Intelligence, Resources, Contracts, Construction, Acquisition, Refit in that order. Market wake calls market execution/replanning before the other Fleet owners. Boot/demand wakes primarily use Headquarters System. | PubSub and durable demand scheduler wake coordination. The 60-second periodic pass covers Contracts/Construction, not all candidate families. There is no single call collecting every family's alternatives before publication. |
| `FleetIntelligence.reconcile/5`, `FleetResources.reconcile/5`, `FleetAcquisition.reconcile/4` | Each can select and publish its own candidate. Intelligence uses current Agent Intents as an occupancy gate; Resources requires the Agent's current Intent list to be empty. Acquisition only plans an offer when no portfolio is current. | Confirmed structural C02/C05 violations. Moving individual guards would not establish one coherent portfolio decision. Independent-Ship and acquisition-while-busy runtime effects remain unmeasured here. |
| `FleetAllocation.select_portfolio/4`, `publish_portfolio/4`, `replan_subgraph/5` | Pure selection and transactional publication primitives exist; publication binds Generation allocation version, active revision, protections, Episode, and outbox. Scoped dependency replacement exists. | Supporting tests qualify these primitives, not a coordinator that submits all candidates from one evidence version. Several callers publish only the first selected commitment. |
| `Evidence`, `DemandScheduler`, `ReadCoordinator`, `CapacityGovernor` | Persist/revoke/fuse demands, retain observations, announce Market evidence, rebuild due timing, share in-flight World reads, and admit API work. | Typed demands and primitive timing are useful. World-read coalescing is not owned-read caching. Shared-egress limits, contextual safety freshness, post-mutation shared-state reuse, and outage-wide sustainable service are not qualified by this proof. |
| `FleetExecution`, `Intents`, `ShipServer` | Market evidence can select a claimed buy leg, execution composes posture/travel, completion can continue into a sell leg, durable arrival rereads Ship state. | R1 demonstrates discovery/arrival reconstruction and a productive trade in some runs, but partial-coverage yielding is inconsistent. It does not measure observation/travel economic calibration or qualify every continuation/capability. |

Inspect the immutable source at the baseline revision: [Reconciler](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet_allocation/reconciler.ex#L48-L71),
[Intelligence occupancy](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet_intelligence.ex#L571-L590),
[Resources gate/publication](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet_resources.ex#L30-L95),
[Acquisition gate](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet_acquisition.ex#L31-L79), and
[allocation publication](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet_allocation.ex#L162-L217).

### Dispatch and recovery (C03/C04/C12)

| Transition | Current owner / durable fact | Qualification |
| --- | --- | --- |
| Select action | `Intents.claim_intent_action/3` writes `in_flight_action` with Claim/portfolio identity. | Separate from preparation; a crash between selection and attempt insertion is not yet injected. An attemptless action must never be inferred absent during recovery. |
| Prepare | `API.send_request` calls `MutationAttempts.prepare_for_dispatch`; preparation writes fingerprint, provenance, operation dependencies, consequences. | Direct ordinary dispatch and ledger structure have supporting tests. Preparation is not independently committed if a caller already owns a transaction. |
| Sent-or-unknown | API request step rechecks singleton/Generation/stop admission and calls `mark_sent_or_unknown`. | Ledger transaction is nested during `Intents.retry_under_current_claim`. The new independent-connection proof establishes that neither the retry nor its send marker is visible. |
| Response | API records succeeded/rejected/ambiguous outcomes; Intent handlers record returned state and progress. | Outcome append and evidence-validation primitives are tested. Death before persistence is now reproduced on the retry send window; the complete boundary sweep remains unproven. |
| Re-entry | `ShipServerBoot -> Intents.rearm_on_boot -> reconcile(nil, :boot, ...)` normally fetches Ship state; an absent action uses `retry_under_current_claim`. | The successful-state restart is proven. Failed/malformed owned reads, creation-before-first-action boot, accepted-effect re-entry after the injected kill, and absent/unknown behavior across every operation remain unproven. |

Source: [action selection](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet/intents.ex#L2864-L2894),
[API dispatch](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/api.ex#L676-L713),
[send admission](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/api.ex#L857-L900),
[ledger transitions](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/mutation_attempts.ex#L100-L162),
[boot evidence guard](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet/intents.ex#L305-L361), and
[enclosing retry transaction](https://github.com/bturney/spacetraders/blob/00a43d8fd47793bc2dc0555d806b678b870d25a6/lib/spacetraders/fleet/intents.ex#L4930-L4964).

## 4. Runtime reproductions

### R1 — favorable fresh-Generation trading: inconsistent qualification

`test/integration/runtime_baseline_proof.exs`, test **C05/C06**:

1. Create/log in the Operator through `/setup`; mint through `/agents/new`;
   select/activate the disclosed Steady growth preset through `/strategy`.
   No observations, contributions, portfolios, Claims, or Intents are seeded.
2. Production coordination discovers the System and starts coverage. A1 exports
   Iron Ore at 10 credits; distant A2 buys at 30. A3 is known but unobserved.
   The game reveals Listings only where the Ship is physically present.
3. Stop the coordinator, demand scheduler, and ShipServer in transit. Let the
   controlled clock pass arrival while they are down; start the production
   coordinator, scheduler, and `ShipServerBoot` to reconstruct the overdue wait.
4. Advance time without calling planners, publishing work, invoking executors,
   or manually waking missing continuations. The failed run's receipts contain
   orbit/navigation/docking and Listing reads at A1/A2/A3, with no trades. The
   latest reviewed run contains purchase/sale receipts and no A3 Market read.
5. Required result: completed buy/sell Intents, empty final Cargo, 175,800 credits,
   and A3's demand still open without an A3 Market read. Failed-run result:
   three completed Intelligence Intents, one infeasible buy, an A3 Market read,
   zero purchase/sale requests, 175,000 credits and 80 fuel. Authenticated Mission
   Control contains the Agent and renders “Outcome status unknown.” The purchase
   assertion fails with expected 1 / actual 0. The latest post-review run meets
   the bounded trade assertions, with completed buy/sell Intents, 175,800 credits,
   20 fuel, and A3 still unobserved; this does not establish reliable yielding.

One earlier fixed-tick run and the latest reviewed production-wake run did
buy/sell 40 units and realize **800 credits**, using **180 fuel**. Other same-seed
runs continued coverage without trading. All retained results remain available;
passing examples are not promoted to dependable qualification. Even their
credit gain was inventory-funded travel, not a net-profit
claim after replenishment. The fixture does not model price movement, refueling,
cooldown actions, multiple Ships, acquisition, or Shared World State changes.
It honors requested pagination but this three-Waypoint run fits one page.
Process restart is not VM/restore proof. Runtime modules still mix some real
wall-clock timestamps with `Clock`; the aligned start and single controlled
wait clock do not qualify arbitrary clock skew or long-horizon freshness. The
failed transcript records when both Listings were acquired (A1 at start, A2 at
start + 60 seconds), then the A3 trip at the next boundary. Their final stale
status after the bounded wake sweep is also retained, rather than described as
fresh forever. Callback sequencing as the cause of the missed first trading
boundary remains unproven; this is not a new observation of the live Fleet.

### R2 — interrupted production boot retry: violated

Same qualification file, test **C04**:

1. Normal authenticated activation selects coverage and its root Intent. The
   controlled transport times out the first orbit request without changing the
   game. Its original attempt becomes durably ambiguous.
2. Stop coordination and restart through `ShipServerBoot`. The boot owner reads
   authoritative Ship posture, proves the first action absent, and selects its
   production retry under the current Claim.
3. The game accepts the retry and records `IN_ORBIT`, but withholds the response.
   The sender reports `Repo.in_transaction?() == true`. An observer connection
   pinned before boot dispatch and held across both inspections has a
   **different PostgreSQL backend ID**, independently of whether the sender
   holds a transaction.
4. The observer sees only the original attempt: `state: absent`,
   `retry_authorized: true`. No retry attempt or sent marker is visible. Kill the
   sending boot process; fresh independent queries see the same lone original,
   while the game still reports the accepted posture and the Intent retains its
   selected orbit fingerprint.
5. The assertion that dispatch is outside an enclosing transaction fails. The
   retained snapshot also demonstrates both absent retry rows. Re-entry after
   this kill is left unproven rather than patched or inferred safe.

In the reviewed run the sender/observer backends were **1627677 / 1627669**;
attempt `1e280f34-2a04-4dc9-a452-91e8b5ba4460` remained absent and retry-authorized.
These IDs identify that run, not fixture expectations. The important facts are
independent visibility, committed absence of the first request, accepted second
request, and loss of second-request evidence on sender death.

The supporting test named “a mutation is durable and sent-or-unknown before
network dispatch” in `test/spacetraders/mutation_attempts_test.exs` inspects the
ledger through its own sandbox transaction. Retain its structural/provenance
claim; it cannot establish the independent durability that R2 disproves.

## 5. Contract/proof matrix

Statuses apply to the **whole named contract** at the inspected revision.
Proven subclaims do not turn a partially qualified contract green. “Violated”
means an explicit contract has a reproduced or inspectable structural
counterexample. Unexecuted causal explanations remain hypotheses.

| Contract | Status | Owning public interface and retained proof | Still-required evidence |
| --- | --- | --- | --- |
| **C01** explicit Strategy semantics/authority | **Violated — structural** | `/strategy -> FleetStrategy.activate/authorize`; immutable activation, stop, revision/CAS and constraint validation pass existing Strategy/LiveView tests. Capability selection searches display prose in `FleetIntelligence` and `FleetResources`; `StandingAuthority` parses English constraints repeatedly. That contradicts the explicit operational representation contract. | Accepted-meaning-preserving semantic representation and migration; dispatch-time consequence accounting and full stop/Claim/revision race scenarios. |
| **C02** coherent whole-Fleet allocation | **Violated — structural** | Production `Reconciler` calls capability-local publication in sequence. Resource/Intelligence whole-Agent gates and Acquisition's portfolio-presence branch contradict independent allocation and acquisition comparison. `select_portfolio/publish_portfolio/replan_subgraph` tests retain primitive ordered protection, CAS, backing and scoped replacement claims. | Runtime independent-Ship/fence and acquisition-while-busy scenarios; all candidate families from one context; independent transactional visibility of publication/outbox and relevant evidence versions. |
| **C03** shared evidence/capacity | **Unproven as a whole** | `Evidence`/`DemandScheduler`/`CapacityGovernor`; existing tests prove demand provenance, compatible fulfilment, revocation, due/deadline semantics and specific backpressure behavior. R1 proves governed discovery/Listing acquisition and arrival reconstruction. | Generation isolation with recurring symbols, every read's visibility/pagination, contextual freshness, mutation response sharing, shared-egress limits, outage recovery and sustainable independent service. Multi-System demand withdrawal described below needs an executable counterexample. |
| **C04** durable mutations/evidence-safe recovery | **Violated — reproduced (R2)** | `ShipServerBoot -> Intents.reconcile -> API -> MutationAttempts`; independent PostgreSQL observer and process kill prove retry evidence loss after transport acceptance. R1 and existing narrow tests retain successful-state restart, ledger validation and dependency-fence claims. | All preparation/send/response/outcome crash boundaries; atomic action-attempt linkage; failed/malformed owned-state re-entry; accepted/absent/bounded-unknown recovery; authority races and independent continuation. |
| **C05** useful adaptive economics | **Violated — structural; R1 inconsistent** | `FleetAcquisition.reconcile` suppresses offer evaluation whenever a portfolio exists, contrary to C05. R1 has both zero-trade and 800-credit runs against the favorable pair. Exposure is described as worst case using fixed 500/250-credit allowances, whose sufficiency is unproven. | Stable productive selection, recurring growth after all costs, market-depth/price changes, defensible downside bounds, meaningful switching and acquisition/preparation comparison while useful work remains current. |
| **C06** coverage/Neutral Wait/stalls | **Unproven as a whole — inconsistent R1** | R1 sometimes continues to A3 without trading, and sometimes yields the profitable A1/A2 boundary. Stable yielding is not qualified. Existing coverage/planning tests constrain negative conclusions; existing Neutral Wait tests exercise stable episode/equivalence and exclude unknown availability/capacity/infeasibility through narrower public calls. | Determine the scheduling-sensitive cause; every discovered System; no artificial future-demand insertion in the complete waiting loop; inaccessible coverage/capability response; linked Unallocated projection and durable detection of genuinely broken progress. |
| **C12** evidence-led contraction/bounded frontier | **Unproven for the whole runtime; baseline scope satisfied** | This baseline retains accepted owners, records only qualified mechanisms, changes the existing scenario seam, and recommends one increment. Current capability-local selection/publication and duplicated prose interpretation remain contraction work. | Reviewed owner-led recovery increment and removal of obsolete caller paths; preservation of unresolved history and safe authority during rollout. Operator review/next accepted work remain pending. |

### Confirmed versus hypothesized

**Confirmed:** R1's fresh discovery/restart with both zero-trade continuation to
A3 and successful trading explicitly retained; R2's retry
durability loss; the current callback sequence, whole-Agent gates,
portfolio-presence acquisition suppression, and prose-derived selection rules.

**Not newly confirmed:** historical reports in
[#501](https://github.com/bturney/spacetraders/issues/501),
[#500](https://github.com/bturney/spacetraders/issues/500),
[#499](https://github.com/bturney/spacetraders/issues/499), and
[#496](https://github.com/bturney/spacetraders/issues/496). Current nil-boot
re-entry explicitly acquires Ship state; the general supplied-observation entry
does not validate its shape. The old missing-state crash is not declared present
or repaired without the failed-read/creation-window proof.

**High-confidence source hypothesis:**
`FleetIntelligence.sync_market_observation_demands/3` builds one System's subject
set, then `Evidence.withdraw_market_demands_outside_subjects/4` withdraws all
`market:%` demands outside that set, without a System filter. Combined with
Headquarters-driven wakes, this appears to lose still-relevant coverage in other
discovered Systems. Qualify that exact public interface before implementation;
R1's single-System fixture cannot settle it.

## 6. One first recovery increment

### Owner/interface

**Evidence/API admission owns recorded dispatch; Ship Execution owns selected
outcomes and evidence-safe re-entry.** Keep `MutationAttempts` behind that
boundary as the one durable attempt/outcome ledger (ADR 0011). The smallest
coherent increment is the Ship mutation send/re-entry protocol, starting with
R2's production orbit retry and contracting the same bypass for the existing
Ship callers. A Fleet-wide planner redesign is not a prerequisite.

The owner-level interface admits a **recorded selected action**, not a callback
whose caller must hold a Claim transaction around the network. It commits the
Intent/action identity and prepared attempt together; commits sent-or-unknown
outside any enclosing caller transaction; revalidates singleton, stop,
Generation, Claim and immutable Strategy authority before bytes can leave;
records response or ambiguity under the same durable attempt identity.

### Safety/recovery and necessary contraction

1. Move action selection/attempt preparation behind that owner so an Intent
   cannot persist an untraceable in-flight action. Reject dispatch from an
   enclosing uncommitted transaction. Remove `retry_under_current_claim`'s
   network callback inside `Repo.transaction`, rather than adding another ledger
   or a wrapper that still permits the bypass.
2. Preserve the current original attempt while classifying independently
   established absence; prepare/link a new retry under still-current authority.
   A killed sender must leave either a committed prepared attempt with safe
   non-send evidence or committed sent-or-unknown evidence. Game-accepted effects
   may not disappear with a local rollback.
3. Route re-entry through authoritative, validated owned-state acquisition.
   Failed/malformed evidence waits/fences the affected scope durably; accepted
   effects are recorded once, absence retries only while selected/authorized,
   and bounded unknowns retain consequence accounting and dependent protections.
4. Remove superseded Ship caller choreography in the same increment. Keep
   independent admissible work, original Episodes/attempts and Operator intent;
   never clear uncertain history by hand or infer “not sent” from a missing row.

### Decisive failing proof and completion boundary

R2 is the initial red test: independently visible `sent_or_unknown` retry and
action linkage must survive sender death, with no enclosing send transaction.
Extend this same scenario at preparation, send marker, response and persistence;
then restart against accepted, absent, failed-read and bounded-unknown effects.
Add Claim/stop/Generation/singleton loss between admission and send, and an
unaffected Ship. Retain R1 as the productive-loop qualification; dispatch repair
must preserve its existing discovery/restart behavior and must not claim the
separate coverage-selection failure repaired without evidence.
Convert satisfied qualification cases into ordinary regression cases as the
accepted recovery increment lands; do not change the failing assertion to accept
the current hole.

### Deployment and recovery boundary

Drain admission or durably engage Emergency Stop before changing the dispatch
owner. Deploy one active runtime, reconstruct all unresolved attempts and selected
actions, and reconcile forward against the live game before dependent mutations
resume. Existing action-without-attempt rows are **unknown historical outcomes**,
not automatically absent; retain/fence them until authoritative effects support a
resolution. A Server Reset or reboot is not their repair mechanism.

Prefer additive linkage and compatible reads before contraction. If the old
binary can still dispatch through the unsafe retry path or cannot understand new
attempt linkage, rollback is safe only with mutation admission held stopped;
otherwise declare the dispatch cutover forward-only and recover forward. A future
implementation must check `docs/operations/project-host.md` and record concrete
schema/binary compatibility before rollout. No deployment is performed by this
baseline.

**Order:** loss-safe dispatch plus evidence-safe re-entry; then useful coherent
allocation/economics qualification. The baseline scenarios need no semantic
Strategy migration or new capability first. Later gates remain in #502, not a
new speculative ticket graph.

## 7. Review and delivery state

The staged baseline diff was reviewed once on both axes through `/code-review`.
Standards reported three findings; Spec reported one (the same contradictory
receipt sentence). All were addressed: committed teardown now removes retained
demands, observations and scoped outbox notifications; the observer holds an
independent nontransactional connection before sender startup; R1's receipts are
attributed to the correct successful/failed runs. Post-review formatting and
warnings-as-errors compilation pass. The targeted reviewed run retains the C04
failure and another passing R1 example, as recorded above.

The canonical gate qualifies the discovered regression suite and shared support,
not the opt-in unmet contracts. No recovery implementation or deployment is
authorized by these results. The handoff returns #503 for Operator review; the
next accepted increment has not yet been materialized.
