# Autonomous Fleet

**Source-controlled overarching product direction, capability ledger and roadmap.** This directory supersedes [#502](https://github.com/bturney/spacetraders/issues/502) as the *planning home*. #502 remains a closed historical record, not a completion certificate. Its unproven ambitions survive in the [capability ledger](capabilities.md). The repository owns the evolving **plan**. **GitHub issues own capability specs and implementation tickets**, their acceptance criteria and proof. Follow [issue-tracker conventions](../agents/issue-tracker.md).

## Choose the next document

| Task | Read |
| --- | --- |
| Decide what the game and Operator experience should become | [Product](product.md) |
| Change module boundaries, coordinated Ship work, evidence, credits or recovery | [Architecture](architecture.md), then the applicable [ADR](../adr/) |
| Determine what is implemented, superseded or still unproven | [Capability ledger](capabilities.md) |
| Choose the next gameplay outcome, competitive destination, or optimization sprint | [Roadmap](roadmap.md) — capability gates first; competition and simulator optimization later |
| Design a new capability, write a spec, or update proof/status | [Change process](change-process.md) and [issue tracker](../agents/issue-tracker.md) — detailed specs and tickets stay in issues |
| Evaluate an economic-default policy or extra Strategy levers | [Economic-first exploration](economic-first-exploration.md) |

## Start a Fleet task

1. **Locate the first unpassed gameplay gate.** Read its last sprint evidence and the capability ledger; check current source and issues before choosing the smallest missing behavior.
2. **Find one owner.** Use the relevant accepted ADR, source module and **GitHub spec issue**. Prefer deepening or removing an existing implementation to creating a parallel decision authority.
3. **Prove the result.** Follow the spec's observable acceptance evidence, distinguish local tests, real-game evidence and simulator-model claims, and update the ledger on the same delivery PR.
4. **Keep the map current.** Change the roadmap or capability ledger when a decision, implementation or qualification changes what should be done next. Keep detailed specs, finite tickets and evidence in GitHub issues, linked to this plan rather than duplicated here.

## Decision authority

The live game and pinned OpenAPI contract govern **game facts** ([ADR 0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md)). Accepted ADRs govern **architecture and durable choices**; the latest approved **GitHub capability spec issue** governs its **behavior and proof**. The [roadmap](roadmap.md) governs **sequence and priority**, subject to explicit Operator product decisions. Issues/PRs hold scoped specs, execution tasks, approvals, discussions and dated receipts.

An older issue statement never silently overrides a later accepted ADR. In particular, [ADR 0016](../adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md) defines today's surplus-first acquisition; [ADR 0017](../adr/0017-nothing-needs-the-operator.md) retires Attention, Manual Intervention, Ship Reservation and in-app Emergency Stop. The approved kill switch is stopping the service; runtime mutation safety and reset fencing still apply.

**Handoff:** Operator Experience Recovery [#757 / PR #802](https://github.com/bturney/spacetraders/pull/802) merged; [acceptance #776](https://github.com/bturney/spacetraders/issues/776) still tracks unproven checks. Simulator [#677 / PR #801](https://github.com/bturney/spacetraders/pull/801) remains separate WIP; its merge/qualification is **not a prerequisite** for the gameplay gates. Consult the [roadmap](roadmap.md) for priority and milestone evidence.

Related agent instructions: [AGENTS.md](../../AGENTS.md), [glossary](../../GLOSSARY.md) (or its accepted successor), and [verification](../agents/testing.md).
