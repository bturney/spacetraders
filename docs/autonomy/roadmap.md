# Autonomous Fleet roadmap

**Long-lived sequence and outcome goals; updated in source control.** Status checked **2026-10-18**. This is the roadmap after [#502](https://github.com/bturney/spacetraders/issues/502): it does not expire when a GitHub issue closes. The [capability ledger](capabilities.md) separately records delivery and proof; [change process](change-process.md) controls revisions.

## Current handoff: finish the two integration workstreams

| Work | Completion checkpoint (check current evidence before updating) |
| --- | --- |
| **Operator Experience Recovery** — [#757](https://github.com/bturney/spacetraders/issues/757), [PR #802](https://github.com/bturney/spacetraders/pull/802) | [#776](https://github.com/bturney/spacetraders/issues/776) accepts Glance → Ships → Why → Grafana on mobile/desktop, checks Earnings and economic selection, cuts over and proves production reads. Earlier integration-child closure is not that acceptance. |
| **Actual-bot accelerated simulator** — [#677](https://github.com/bturney/spacetraders/issues/677), [PR #801](https://github.com/bturney/spacetraders/pull/801) | The real application boots into a separately pinned private HTTP world and migrated PostgreSQL; semantic time, API scarcity, isolation, restart, gameplay and economic credibility are qualified at their declared levels. [#799](https://github.com/bturney/spacetraders/issues/799)/[#800](https://github.com/bturney/spacetraders/issues/800) own bounded full-system/protected-host qualification. A merged integration PR is not proof of 336-hour runs or approval for live/protected-host operation. |

**Assumed start for the next roadmap:** both specifications have cleared their own acceptance criteria, and the accepted changes are on the intended target branch. **This is a planning assumption, not a claim that the checkpoint happened.** Upon that handoff, update the table, [capability ledger](capabilities.md), pinned simulator revision/fidelity limitations and the true baseline before accepting a new capability.

Completed foundations to reuse: Gate 2A partial-evidence trading ([PR #676](https://github.com/bturney/spacetraders/pull/676)), Gate 2C surplus-first acquisition ([PR #737](https://github.com/bturney/spacetraders/pull/737); [ADR 0016](../adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md)), and the bounded #715 simplification. Reopen one only for demonstrated residual failure.

## After the handoff: evidence, then one improvement

### 0. Establish the actual baseline

Run **bounded, approved** actual-bot scenarios and inspect retained production Earnings without inventing simulator-to-live fidelity. Record, for each comparable world/policy: realized or explicitly unknown Net Earnings, credits, economic throughput per Ship-hour, API requests and deferrals by purpose, opportunity cost, acquisition and idle-Ship decisions, wait/stall causes, gate/chart milestones, constraint/safety events and recovery. Keep trial/mutation/gameplay authorization separate from a documentation approval.

**Exit criterion:** a reproducible, pinned baseline plus a ranked list of *observed* limitations, including unknown or model-sensitive results. A completed report can legitimately conclude that evidence is insufficient to choose a policy.

### 1. Make the simplest economic Fleet consistently productive

Evaluate a built-in **economic-growth default** against the current immutable Strategy, holding code or policy constant as appropriate. Compare direct trading, evidence gathering, fuel, capital growth, acquisition and retained work using net marginal value over the remaining Generation Horizon. Price API scarcity explicitly, but continue protected recovery admission.

**Exit criterion:** on matched relevant scenarios, the chosen policy improves a declared economic outcome (or demonstrates a justified trade-off), remains useful with partial evidence and imperfect markets, does not create polling/refuel drain, and has recorded accepted/rejected alternatives with attributable actuals. Commit an explicit policy decision before deleting old Strategy controls. See [exploration](economic-first-exploration.md).

### 2. Add deliberate multi-Ship cooperation

Let one Fleet-level Candidate Contribution require several roles, e.g. producer + hauler plus any useful support, under **one** allocation publication, Claims, Reservations and Pledges. Avoid a second “team engine.” Keep independent Ships productive when a team step blocks, and replan only its affected dependency subgraph.

**Exit criterion:** authenticated/scenario proof of a common deliverable achieved by two cooperating Ships, correct shared-resource accounting, a third independent Ship making progress, restart recovery and bounded failure/replan. A test proving that two Ships merely ran simultaneously is insufficient.

### 3. Expand economically meaningful gameplay

Use the *current pinned OpenAPI inventory* to identify the highest-value autonomous capability gap: more Systems and Markets, chart rewards/exploration, contracts, extraction/refining, construction/gates, trade support or other supported actions. **Choose by marginal expected outcome and bottleneck**, not endpoint count or ticket age. Ensure all discovered-System Marketplace coverage and useful action on partial evidence remain achievable.

**Exit criterion per selected family:** it becomes reachable through the normal Fleet decision/execution path, respects receipts and incomplete knowledge, cooperates with existing work and has a faithful end-to-end proof. The larger destination is full API-family coverage; only count an operation whose behavioral owner and recovery are demonstrated.

### 4. Qualify reset-to-reset autonomy

Exercise actual long-lived behavior with API pressure, held/unknown mutations, concurrent Fleet work, outages, application restarts and definitive Server Reset replacement. Use the simulator to target failure windows; use a separately approved live trial for claims only the real game can establish.

**Exit criterion:** an inspectable multi-day result with preserved economic and causal evidence, bounded failure handling, no duplicate game mutations, no stale-generation authority, continued useful work and clear residual uncertainty. A 336-hour extended simulation is not itself proof that a real reset occurred.

### 5. Explore alternate ways to play

Only after a productive, explainable baseline, compare alternate policy modes (gate-first, chart-first, growth-first or risk-aware) under matched bounded experiments. Expose only levers that alter interesting observed trade-offs, not a generic Strategy rule builder.

**Exit criterion:** at least one supported alternative with a documented behavioral difference, truthful comparative evidence and an understandable Operator-facing choice. If no difference is fun or useful, keep the simpler default.

## How to choose the *next* capability

This is a **decision queue, not a rigid five-phase schedule**. At each completed checkpoint, inspect the [ledger](capabilities.md) and the latest experiment/production results. For each candidate record: (1) real outcome currently blocked; (2) measured or bounded expected benefit; (3) binding resource (Ship time, credits, API capacity, evidence, attention or correctness); (4) uncertainty and how cheaply it can be reduced; (5) safety/recovery risk; (6) complexity added or removed; (7) smallest end-to-end proof.

Prefer: **safety regression that blocks all progress → currently binding economic loss → cheap decisive experiment → useful new capability → speculative flexibility**. Promote one coherent, bounded spec at a time, with the explicit Operator decision required for policy changes, experiments and deployment. A blocked or unsupported opportunity can remain **inconclusive**; creating a ticket is not evidence that the opportunity is valuable.

## Lifecycle

- **Planned:** a reviewed versioned [spec](specs/README.md) exists; work not automatically authorized.
- **Integrating:** code under development; an integration branch is not deployed or main.
- **Implemented:** merged source and required local gate pass; precise scope recorded.
- **Qualified:** the required actual-bot/live/scenario evidence meets declared conditions, and residual limitations are visible.
- **Superseded:** a later accepted decision links the replacement; retain history, not duplicate roadmaps.

Update this file **when priorities or milestone status change**; update [capabilities.md](capabilities.md) **when behavior or proof changes**. Preserve immutable run/evidence receipts as linked artifacts. A closed GitHub issue does not close a roadmap goal.
