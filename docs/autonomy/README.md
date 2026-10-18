# Autonomous Fleet

**Source-controlled product direction, capability ledger and roadmap.** This directory supersedes [#502](https://github.com/bturney/spacetraders/issues/502) as the *planning home*. #502 remains a closed historical record, not a completion certificate. Its unproven ambitions survive in the [capability ledger](capabilities.md). The repository, not an always-open tracking issue, owns future updates.

## Choose the next document

| Task | Read |
| --- | --- |
| Decide what the game and Operator experience should become | [Product](product.md) |
| Change module boundaries, coordinated Ship work, evidence, credits or recovery | [Architecture](architecture.md), then the applicable [ADR](../adr/) |
| Determine what is implemented, superseded or still unproven | [Capability ledger](capabilities.md) |
| Choose the next investment after current integrations or see active priorities | [Roadmap](roadmap.md) |
| Design a new capability, write a spec, or update proof/status | [Change process](change-process.md) and [spec index](specs/README.md) |
| Evaluate an economic-default policy or extra Strategy levers | [Economic-first exploration](economic-first-exploration.md) |

## Start a Fleet task

1. **Locate the outcome and status.** Read the relevant roadmap entry and capability row. Their state snapshot is dated; inspect current GitHub issues, merged PRs and actual source before claiming readiness.
2. **Find one owner.** Use the relevant accepted ADR, source module and spec. Prefer deepening or removing an existing implementation to creating a parallel decision authority.
3. **Prove the result.** Follow the spec's observable acceptance evidence, distinguish local tests, real-game evidence and simulator-model claims, and update the ledger on the same delivery PR.
4. **Keep the map current.** Change the roadmap or capability ledger when a decision, implementation or qualification changes what should be done next. Keep evidence and finite tickets on GitHub, not as a second permanent roadmap.

## Decision authority

The live game and pinned OpenAPI contract govern **game facts** ([ADR 0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md)). Accepted ADRs govern **architecture and durable choices**; the latest accepted in-repo capability spec governs its **behavior and proof**. The [roadmap](roadmap.md) governs **sequence and priority**, subject to explicit Operator product decisions. Issues/PRs hold discussion, execution tasks, approvals and dated receipts.

An older issue statement never silently overrides a later accepted ADR. In particular, [ADR 0016](../adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md) defines today's surplus-first acquisition; [ADR 0017](../adr/0017-nothing-needs-the-operator.md) retires Attention, Manual Intervention, Ship Reservation and in-app Emergency Stop. The approved kill switch is stopping the service; runtime mutation safety and reset fencing still apply.

**Transition checkpoint (2026-10-18):** Operator Experience Recovery [#757 / PR #802](https://github.com/bturney/spacetraders/pull/802) and actual-bot simulation [#677 / PR #801](https://github.com/bturney/spacetraders/pull/801) were in progress when this roadmap was adopted. This roadmap is written for the decisions *after both are finished*, but does not assert that either is merged, accepted in production or qualified. See [roadmap](roadmap.md) for the handoff condition.

Related agent instructions: [AGENTS.md](../../AGENTS.md), [glossary](../../GLOSSARY.md) (or its accepted successor), and [verification](../agents/testing.md).
