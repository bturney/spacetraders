# Operator experience, proof and delivery contracts

> Imported from [#502](https://github.com/bturney/spacetraders/issues/502) on 2026-10-18. The contract text below is preserved from that issue without semantic edits. Qualification status is tracked separately; a written contract is not proof of implementation.

### C09 — Complete, truthful Operator experience

Retain [Mission Control information architecture](https://github.com/bturney/spacetraders/issues/311) and [Prototype intuitive Fleet Strategy command](https://github.com/bturney/spacetraders/issues/305) as the complete interaction target. Do not substitute a defect dashboard or API browser for that design.

Mission Control identifies revision, Agent, Generation, capable state, ordered objective evaluations, Fleet contribution, real Attention/Intervention, and notable Activity. Operations defaults to objective-grouped Work with peer purpose-first Ships. World links Atlas and Intelligence, distinguishes known existence from fresh facts, renders transit rather than false endpoint positions, and expands relevant facts in place. Strategy is readable standing intent with curated goals/constraints, persistent drafts, exact change review, and explicit activation.

Objective/Endeavor/Ship/Waypoint/Contract/Construction/revision/Generation destinations remain contextual and stable; Market and Shipyard are Waypoint context, not primary products. Search is local-first and cannot be a mutation console. Secondary Activity, Generations, Settings, and Grafana preserve the same mental model. A Ship Reservation is durable and reason-bearing; exceptional authenticated Manual Intervention cannot create simultaneous autonomous authority or routine Manual Control.

Neutral Wait's concise summary preserves ADR 0012: fixed reason, limitation, coverage when applicable, last evaluation, and next observation time; identities and deeper evidence are disclosed on demand. Unallocated Ships link to the applicable episode. Live refresh preserves drafts, selection, scroll context, and useful explicitly stale state. Unknown data is not zero. Desktop and phone are both tested, with calm restrained visual hierarchy and motion only when it communicates state.

### C10 — Durable explanation, observability, and calibration

Decision Episodes join Strategy and objective evaluation to alternatives, selected/retained/superseded work, binding constraints, evidence, expected outcome, calibration version, attempts, and actual outcomes. Original causal provenance is retained; evolving re-evaluation evidence is distinguishable from original selection evidence. Each material allocation disposition has a compact decisive reason; opaque scores are not the authoritative explanation.

Economics separate protected, reserved, deployed, and available credits; realized gains, losses, travel, observations, acquisition, and preparation are attributable. Measure wall-clock and Strategy-capable outcome rates, Ship-time classes, evidence coverage/reuse/cost, API pressure/service delay, recovery, and telemetry completeness. Unknown intervals, estimates, realized results, and reconstructed facts remain distinct.

Keep the five agreed Grafana families: Strategy Outcomes, Economics and Capital, Fleet and Logistics, Intelligence and API Capacity, and Reliability and Recovery. Contextual links carry durable identity and time window without secrets. Identity-rich evidence belongs in durable records, logs, and traces rather than unbounded metric/stream labels. Unrecognized gameplay errors preserve their raw redacted envelope and a bounded unknown-class signal; credential misuse is distinguishable from reset and ordinary eligibility rejection.

Calibration changes only declared bounded system parameters at reconciliation boundaries. Versions retain provenance, reproduce prior values on reversal, and cannot edit objectives, priorities, accepted preset choices, Preferences, Hard Constraints, or the active revision. Compact essential history survives for the Strategy lifetime; high-resolution retention covers at least current and previous Generations. Observability is disposable and cannot become gameplay correctness or authority.

### C11 — Recovery route and completion gates

These are **qualification gates**, not five oversized implementation tickets. Work is generated from actual contract failures in the current gate; existing conforming code may pass without reimplementation. Truthful projection, causal telemetry, and forward recovery accompany every increment, not just the final phases.

| Gate | Fixed point and decisive proof |
| --- | --- |
| 1. Trustworthy authority and execution | Establish the contract/proof baseline; prove genuinely committed attempt evidence before send, evidence-safe re-entry, accepted/absent/unknown recovery, stop/Generation/Claim fencing, and independent continuation. No new capability expansion precedes closing structural dispatch/recovery holes. |
| 2. Useful coherent autonomy | From normal Strategy activation and fresh authoritative bootstrap, the real coordinator discovers distant opportunities, yields partial coverage to admissible trading, completes profitable buy/travel/sell cycles in a favorable game, supports independent Ships and acquisition, adapts to changed economics, and deliberately waits when no worthwhile work exists. Persisted decisions and realized costs explain every result. |
| 3. Complete coordinated capability | Qualify every API owner through production planning/allocation/execution, shared outcomes, multiple Ships, Fleet growth/readiness, repair/scrap, and inter-System operation. Dependency changes and failure recovery retain unrelated work. Metadata and isolated adapter calls are not capability proof. |
| 4. Complete product and optimization | Deliver the accepted information architecture across desktop and phone, truthful wait/fault/Attention presentation, navigable causal evidence, comparable outcomes, the five diagnostic families, and bounded reversible calibration. Validate real visual workflows as well as LiveView semantics. |
| 5. Reset-to-reset proof and handoff | Pass the deterministic operating-domain/failure/lifecycle sweep, then the Operator-approved multi-day protocol with defined duration, thresholds, exercises, and evidence schema before the trial starts. Include definitive reset or an explicitly approved equivalent, replacement/bootstrap/resumed Strategy, deploy/failure/outage/ambiguity/Strategy/stop exercises, and honest capability, outcome, intervention, and unknown-gap reporting. |

The baseline records each contract as **proven, violated, or unproven**, with test/production evidence and the exact revision inspected. First recovery work is driven by a falsifiable failing scenario and its owning interface. Do not mark a module retained merely because it exists or a ticket closed; equally, do not rewrite a demonstrated conforming implementation for aesthetic uniformity.

### C12 — Graceful in-place change and a bounded delivery frontier

Each change has one clear owner and one behavioral purpose. Move duplicated knowledge behind the owner, replace callers with the small interface, and remove obsolete paths in the same completed increment or its explicit safe contraction. Do not layer a new framework over old authorities, add translation matrices across every caller, or introduce a general seam whose variation is hypothetical.

Preserve Operator-owned intent, current unresolved attempts, safe current authority, and useful history. Migrate only records necessary for a changed contract; reconstruct disposable projections from evidence. Never drop unresolved state, repair uncertain facts by hand, or claim that reset/reboot substitutes for recovery. Legacy Jobs, Policies, and routine Manual Control remain retired.

This issue is the canonical replacement spec and planning index. Its native sub-issues are the current work surface. Start with one contract/proof baseline ticket. After review, materialize only the next coherent increment's agent-sized work with native dependencies; keep later gates here rather than pre-generating another full-project graph. A new defect is attached to an owning contract and proving scenario before another independent leaf is created. Existing closure records retain history rather than becoming a hidden competing backlog.

## Testing Decisions

### The principal seam

Retain the already-decided **autonomous runtime scenario seam**: authenticated Operator interfaces, controlled SpaceTraders transport, shared controllable time, real PostgreSQL, process/VM interruption, and observed mutations, durable evidence, notifications, and rendered Mission Control. Planning, allocation, admission, and execution are the production implementation under test. There is no new parallel simulator or test-only orchestrator.

Tests claiming end-to-end autonomy may seed normal Operator/world starting fixtures, but must activate through public authority and let the production runtime choose work. They may not inject the winning Candidate Contribution, publish the expected portfolio, call the executor directly, or manually wake each missing continuation and then claim the autonomous loop works. Lower public-module tests retain their narrower, explicitly named scope.

### Required proof families

| Proof family | Required observable result |
| --- | --- |
| Dispatch and recovery | Kill before/after preparation commit, sent-or-unknown commit, request send, response, and outcome persistence; an independent reader/restarted runtime finds sufficient evidence. Missing owned-state reads cannot progress. Confirmed absence permits only the still-authorized retry; confirmed effects are never sent twice. |
| Productive Fleet loop | Stateful favorable Market scenario begins with fresh Generation and incomplete knowledge, discovers a distant route, yields coverage at an observation boundary, realizes net credit growth after costs, and continues through transit and restart without test-directed planner/executor choreography. |
| Scarcity, independence, and waiting | Higher-priority envelopes remain protected; one occupied/fenced Ship does not exclude another; acquisition competes alongside current work; compatible commitments survive changes. Complete unfavorable coverage becomes stable Neutral Wait; incomplete/unreachable coverage, unknown availability, and capacity deferral never produce false negative or wait facts. |
| Complete capability and lifecycle | Every operation is uniquely classified and reachable through its declared owner. Capability-family scenarios cover the required prerequisite, success, rejection/absence/ambiguity, stale evidence, and scoped failure semantics. Run the deterministic domain-by-failure sweep plus Strategy revision, Emergency Stop/resume, singleton loss, Server Reset, bootstrap, and restore/forward reconciliation. |
| Operator experience and outcomes | Public projections/LiveViews match durable decisions and game evidence; real desktop/phone checks prove layout, navigation, timing, draft/selection stability, state distinctions, acknowledgement versus resolution, contextual analysis, causal joins, economics, retention, and reversible calibration. |

Keep deterministic Planning/Allocation property and scenario tests for broad invariant coverage: exclusive Claims, bounded Reservations, backed Pledges, stable ties, meaningful switching, ordered protection, stale-version rejection, and one active root Intent per Ship. Keep real PostgreSQL transaction/constraint/outbox tests and generated API/no-bypass checks as supporting contract seams.

Use a stateful controlled game that enforces relevant physical presence, travel, cooldown, Cargo, credits, pagination/visibility, and shared-world changes. Its transport records what actually left the process; internal calls or fixture counts are not mutation proof. Use real independent transaction visibility for crash-boundary claims, and one controllable clock for decision/wait assertions.

The existing ScenarioCase, reset-spanning scenarios, observation scheduling scenarios, capability-family tests, authenticated LiveView tests, and OpenAPI conformance checks are prior art. Extend them at their interfaces. Passing the current mint/timer scenario or negotiation adapter scenarios is valuable narrow evidence, not proof of profitable Fleet autonomy or complete API reachability.

For each gate, record commands, terminal exit/result, revision, environment, contract-to-test mapping, and remaining unproven behavior. The canonical verification gate must have a known result; a truncated log, flaky baseline, skipped scenario, or stale previous run is not a pass. Reuse the separate tooling issues if verification infrastructure blocks a trustworthy result. Live-game proof follows an approved protocol and cannot repair defects ad hoc or silently lower acceptance thresholds.

## Acceptance Criteria

| Contract | Completion obligation |
| --- | --- |
| C01 | Machine-interpretable Strategy semantics, immutable Operator intent, enforceable constraint validation, correct Standing Authority, stop/resume, and no prose-dependent capability selection. |
| C02 | One coherent whole-Fleet decision with ordered protection, retained independent commitments, versioned atomic publication, and no whole-Agent busy gate or acquisition suppression by portfolio presence. |
| C03 | Shared Generation-scoped evidence, contextual freshness, revocable durable demand, reconstructed wakeups, protected strategic admission, shared-egress protocol limits, and visible sustainable backpressure/recovery. |
| C04 | Durable pre-send attempt linkage visible outside the caller transaction, one recovery authority, evidence-safe execution, accepted/absent/bounded-unknown reconciliation, and no blind replay or unrecorded in-flight state. |
| C05 | Useful adaptive contribution selection with explicit costs/uncertainty, market-depth-aware economics, realized accounting, acquisition alongside current work, and no unbounded keep-busy activity. |
| C06 | Discovered-System bounded coverage, partial-evidence action and complete-evidence negative conclusions, stable correctly minted Neutral Wait, linked Unallocated Ships, and genuine durable stall Attention. |
| C07 | Restart/restore/lock/stop safety, definitive reset fencing, automatic permitted replacement/bootstrap, preserved Strategy/history, and invalid old-world authority. |
| C08 | Every current API operation uniquely owned, evidence/recovery-classified, behaviorally reachable when relevant, and qualified across complete capability families and coordinated outcomes. |
| C09 | The complete accepted outcome-first information architecture works on desktop and phone, with stable live behavior, genuine authority controls, truthful state, and contextual entity/evidence navigation. |
| C10 | Durable causal explanation and truthful normalized economics/productivity, bounded metrics, contextual diagnostics, retention, and reversible calibration that cannot alter Strategy. |
| C11 | All five gates have independently inspectable evidence, a known canonical verification result, and an approved multi-day reset-to-reset handoff. |
| C12 | Retain/refactor/replace decisions are evidence-led; one authority per fact and a small active work frontier replace the old patch/ticket layering. |

Closing this issue requires all contracts and all gates, including still-unproven behavior in code whose historical ticket is already closed. A conformance manifest or one positive trading demo cannot waive recovery, full capability, Operator experience, or the final trial.

## Out of Scope

1. Bankruptcy of unrelated repository tooling, test-infrastructure, development-harness, historical Manual Control, or program-roadmap work.
2. A wholesale rewrite, repeat database/stack migration, distributed runtime/workflow infrastructure, or preserved internal interfaces solely for compatibility.
3. Routine Manual Control, revived Jobs/Policies, LLM gameplay decisions, silent Strategy edits, mandatory phase/preset switching, or a generic planner-rule builder.
4. Guaranteed globally optimal or leaderboard-winning play, unsupported mechanics inferred from old research, or treating local observations as Shared World State locks.
5. Extra product concepts beyond the accepted destination, decorative immersive work before useful behavior, external push/TV mode, and speculative optimization proposals that would need a new Operator decision.

## Further Notes

**Current state:** the newest `## Current state` comment on this issue ([2026-10-10](https://github.com/bturney/spacetraders/issues/502#issuecomment-6100191954)) holds gate status, landed interfaces and open obligations. Read it before planning the next slice; replace it rather than appending status updates.

The closed map and resolutions remain the source of product and architectural decisions. This spec supersedes the delivery structure in [Implement reset-to-reset autonomous Fleet Strategy](https://github.com/bturney/spacetraders/issues/312), the overlapping [Design the reset-start autonomous observation and economic operating loop](https://github.com/bturney/spacetraders/issues/469), their remaining runtime work, and directly overlapping runtime defect/architecture/research tickets listed in the supersession register attached to this issue.

Accepted later refinements are retained: [One recovery authority per mutation](https://github.com/bturney/spacetraders/blob/main/docs/adr/0011-single-recovery-authority-for-mutations.md), [Decide the bounded Marketplace coverage contribution contract](https://github.com/bturney/spacetraders/issues/482), and [Decide the Neutral Wait state contract](https://github.com/bturney/spacetraders/issues/487). Pending corpus-derived Game Phase/preset proposals are not silently promoted to accepted design. Their useful evidence feeds costs, capability guards, freshness, and future reviewed recommendations inside the established model.

The original map's staged roadmap remains useful historical rationale for safe activation, telemetry, and contraction. Its already-landed scaffolding is not repeated, and its eighteen fixed points are not the new executable backlog. The replacement route starts by qualifying present authority and useful behavior.

All old issue bodies, discussions, relationships, and closed decisions are retained. The attached register maps each superseded open issue to the replacement contract or explicitly deferred proposal, and records the unrelated open issues preserved. Source investigations stay evidence; the replacement spec and its reviewed current leaves become the delivery authority.
