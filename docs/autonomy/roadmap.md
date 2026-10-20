# Autonomous Fleet roadmap: capability first, optimization later

**Sequence:** useful gameplay → competitive baselines → accelerated optimization. **Core gates block advancement until an outcome is proven; sprints choose the smallest missing behavior needed for the current gate.** This roadmap owns direction and milestones. [GitHub issues](../agents/issue-tracker.md) own scoped specs, tickets, acceptance thresholds and proof receipts; the [ledger](capabilities.md) tracks existing behavior and gaps.

**Decision: 2026-10-19.** The simulator is an optimization tool, **not a prerequisite** for building or qualifying gameplay. [Simulator spec #677](https://github.com/bturney/spacetraders/issues/677) and [PR #801](https://github.com/bturney/spacetraders/pull/801) remain independent work in progress. Their schedule, conflicts and qualification do not block the core roadmap. This decision does not alter their scope or authorize any simulator/host work.

## Current position

- **Operator Experience Recovery:** [#757](https://github.com/bturney/spacetraders/issues/757) closed and [PR #802](https://github.com/bturney/spacetraders/pull/802) merged. The Operator finds it broadly usable, with minor visual defects. [#776](https://github.com/bturney/spacetraders/issues/776) still owns formal device, cutover and deployed-query acceptance; address residual defects as scoped follow-ups.
- **Economic evidence:** the [accepted 24-hour production soak #691](https://github.com/bturney/spacetraders/issues/691) proved 279 known-Net completed trips and **+427,124 credits Net Earnings** on its pinned earlier release. That is evidence of sustained profitable trading, **not** proof of productive Fleet growth or the newest build.
- **Current frontier:** establish which part of the **economic foundation** remains unproven on current code, then select a small end-to-end gameplay increment. Use retained production evidence and deterministic tests. Simulator completion is not a handoff condition.

## Open-issue signals for sprint selection (2026-10-20)

**Existing tickets, not a new feature sequence.** At each sprint decision, compare current evidence for these open issues against the active outcome gate. Fix demonstrated regressions that make gameplay or its evidence untrustworthy; defer work whose observed impact is smaller than the next useful gameplay increment. Issue bodies own requirements, proof and disposition.

| Outcome at risk | Relevant open issues | Selection rule |
| --- | --- | --- |
| **Gate 0 — productive reinvestment** | [#739: Ship acquisition not firing](https://github.com/bturney/spacetraders/issues/739) | **Investigate first** when choosing the next economic sprint: on current code, show the unmet Ship-bound work, horizon, surplus and recorded refusal. Fix a provably missed profitable investment, not an arbitrary failure to purchase a third Ship. |
| **Truthful economic decisions** | [#813: skipped buys hidden](https://github.com/bturney/spacetraders/issues/813), [#816: false “Busy, not earning”](https://github.com/bturney/spacetraders/issues/816) | **High-impact corrective work:** distinguish price-guardrail refusals from low earnings, and expose why a buy was skipped. The existing production receipts establish a misleading Operator signal, not that the price policy should be changed. Repair before treating those summaries as gate evidence. |
| **Truthful scouting / Ship roles** | [#814: probe mislabeled Trading](https://github.com/bturney/spacetraders/issues/814), [#815: missing Ship class](https://github.com/bturney/spacetraders/issues/815) | **High-impact correction plus useful enabler:** report actual intelligence work as scouting; preserve/display frame and role when worthwhile. Apply #814 without waiting for #815. These matter when demonstrating the charting gate. |
| **Usable Operator evidence** | [#740: Mission Control slow to load](https://github.com/bturney/spacetraders/issues/740) | Reproduce on the merged Operator build before prioritizing. If confirmed, measure the bottleneck and preserve historical Generations while repairing the read path. |

**Historical and observational issues:** [#663](https://github.com/bturney/spacetraders/issues/663) describes an older no-trade failure; [#691](https://github.com/bturney/spacetraders/issues/691) later proved profitable trading on another pinned release. Recheck before counting #663 as a current blocker. Metrics requests such as [#664](https://github.com/bturney/spacetraders/issues/664), [#665](https://github.com/bturney/spacetraders/issues/665) and [#666](https://github.com/bturney/spacetraders/issues/666) become sprint work only when their missing signal prevents an important decision or proof. Each repair stays in its **existing issue**, separate from merged Operator recovery [#757](https://github.com/bturney/spacetraders/issues/757) and simulator WIP [#677](https://github.com/bturney/spacetraders/issues/677).

## Stage 1 — Build a competitively capable engine

These are **outcome gates**, not an ordered feature backlog. Only the first unpassed core gate owns the next primary sprint. Prove the smallest credible representative outcome before broadening coverage; retain larger unknowns in the [ledger](capabilities.md).

| Gate | Observable outcome | Proof to advance | Current state |
| --- | --- | --- | --- |
| **0. Productive economic foundation** | The unattended Fleet earns attributable Net Earnings and can **reinvest in useful capacity when an opportunity warrants it**. | Preserve profitable-trading evidence, qualify current-build economics and recovery, and show that surplus-safe Ship investment is either deployed into productive work in a justified case or correctly refused with evidence in an unjustified case. Buying an idle Ship is not growth. | **Active; partial historical earnings proof.** Fleet-growth outcome unproven. |
| **1. Exploration that produces charts** | The Fleet autonomously reaches useful uncharted territory and **submits charts**, while continuing justified independent work. | An end-to-end chart contribution with authoritative submission attribution, meaningful travel/discovery decisions, bounded credit/API exposure and recoverable failure. A System scan or generated endpoint alone does not count as a submitted chart. | **Blocked by Gate 0; specific behavior gaps to inspect then.** |
| **2. Construction and logistics** | The Fleet sources and delivers required materials and **completes its initially unfinished Headquarters System Jump Gate** through its own contributions. | Credible end-to-end material acquisition, transport, delivery and authoritative completion receipts, including the mint-to-completion clock. Identify simulation/test-only evidence separately from live game proof. | **Blocked by Gate 1.** |
| **3. Integrated Fleet intelligence** | Multiple Ships pursue economic, charting and construction outcomes without starving one another; coordinated work is possible where needed. | A representative mixed-work scenario with real shared-resource accounting, independently productive Ships, at least one genuinely coordinated multi-Ship outcome, and safe wait/restart/replan handling. A pair of Ships acting simultaneously is not coordination. | **Blocked by Gate 2.** |
| **4. Competitive baselines** | The engine can meaningfully pursue **credits, submitted charts and home-gate speed** across Generations. | Record comparable, attributable results for all three pursuits, Fleet composition/Ship time/API use, reset identity and known measurement gaps. Store live and test-world evidence separately. A baseline is a measured starting point, not an invented leaderboard win. | **Blocked by Gate 3.** |

**Gate rules:** pass/fail/inconclusive comes from a pinned, reviewable receipt, **not** a merged implementation or closed issue. Freeze the relevant acceptance conditions before qualifying an attempt; revise goalposts prospectively and preserve earlier evidence. A failed sprint stays on the same gate and changes the next hypothesis. Safety work and a small shared enabler may proceed when necessary for the current gate, but cannot certify a later gate by proxy. Where no economically justified purchase exists, a truthful refusal is required; do not force wasteful growth merely to satisfy a metric.

**Proof without the simulator:** use deterministic application/scenario tests for new behavior and retained, separately authorized real-game observations where practical. Label test-only claims as such and keep unknown economics unknown. Do not conflate test completion with actual live construction or leaderboard placement. Qualifying a new behavior must preserve [architecture invariants](architecture.md) and independent gameplay/deployment approvals.

## Stage 2 — Compete and accumulate history

The three ultimate destinations are **independent**; a win in one does not gate the others.

| Destination | Verifiable high-water mark |
| --- | --- |
| **U1. Top 10 in credits** | This Agent is ranked in the official live `mostCredits` top ten. Retain Agent/Generation, timestamp, actual credits, position and 10th-place reference. |
| **U2. Top 10 in submitted charts** | This Agent is ranked in the official live `mostSubmittedCharts` top ten. Retain Agent/Generation, timestamp, submitted-chart count and position. |
| **U3. Fastest home-system Jump Gate** | Improve the best *comparable, Fleet-attributable* time from successful mint to authoritative completion of the initially unfinished Headquarters System gate. Retain world conditions, timestamps, construction receipts and limitations. No official global construction-speed leaderboard is assumed. |

Top-ten credits and chart placements may occur **in different Generations**. **Stretch:** both top-ten places **at the same observed time in one Generation**, proven by an authoritative snapshot. Once earned, retain the historic record even if a later leaderboard changes; tighter ranks, faster gate times and consistency can become later goals.

**Personal Generation high scores** is an eligible candidate outcome: durable, comparable records for per-Generation Net Earnings, official charts submitted, fastest attributable home-gate completion and other supported scores. Capture provenance across resets; show incomplete past scores as **unknown**. Consider early data retention when it becomes a real risk, but prioritize this through the same sprint decision as any gameplay outcome—not through a prerequisite or extra work in #757/#677.

## Stage 3 — Optimize with accelerated simulation

**After meaningful gameplay breadth and baseline results**, use the actual-bot simulator to compare strategies, code or allocation trade-offs over matched worlds: credits versus charting, investment versus liquidity, Ship specialization, construction critical paths and reset resilience. Require declared fidelity and scenario limits before using results to change policy. A faster simulated gate result is not a live record.

The simulator may keep integrating in parallel or pause independently; **neither path gates Stage 1 or 2**. Resume or prioritize its qualification when a specific important optimization question would benefit from controlled, shorter feedback.

## Evidence-led sprint loop

1. **Inspect:** read the first unpassed gate, last receipt, [capability ledger](capabilities.md) and active source. Name the *missing useful behavior or demonstrated failure* that most constrains the outcome. **Done:** one evidenced bottleneck or explicitly unknown cause.
2. **Choose:** compare repair/deletion, a narrow new gameplay loop, or a bounded test. Favor **new meaningful gameplay reach** over tuning an already-working limited action set, unless safety/economics regressions block progress. **Done:** one hypothesis, smallest end-to-end proof, rejected options and risk bounds.
3. **Specify in GitHub:** derive one scoped capability spec issue and finite tickets from the gate; record detailed thresholds, authority and exact evidence in those issues. **Done:** an implementer can act without inventing scope.
4. **Deliver and prove:** reuse existing runtime owners, preserve API/mutation/reset invariants, verify the increment and collect separately authorized game evidence. **Done:** receipt establishes **passed / failed / inconclusive** without overstating fidelity.
5. **Retrospect:** explain actual versus expected behavior and the next bottleneck. On **pass**, advance one gate and re-evaluate priorities; on **failure/inconclusive**, stay on the gate and select the next sprint. Update this roadmap for milestone/priority changes and the [ledger](capabilities.md) for high-level delivery/proof.

Potential increments include discovery and chart submission, contract fulfillment, extraction/refining, construction supply, trade logistics, investment, or coordinated Ships. **The evidence picks the next increment; this list is not an implementation order.** The [product](product.md), [architecture](architecture.md), accepted ADRs and live game remain authoritative in their respective areas.
