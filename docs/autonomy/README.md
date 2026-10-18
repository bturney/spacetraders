# Autonomous Fleet: design and roadmap

This directory gives [#502](https://github.com/bturney/spacetraders/issues/502)'s accepted reset-to-reset autonomous Fleet Strategy contracts a versioned, reviewable home in the repository. The six contract documents retain the 2026-10-18 issue body, in original order and **without changing its requirements**. Their section headings retain C01–C12 and the acceptance/proof decisions. The issue remains the discussion/history and current implementation-frontier index.

**Transition rule:** until this migration is merged and the issue is updated to point here, #502 is still the authoritative contract. Before merging, reconcile any new Operator decisions or contractual changes made on the issue since the copied snapshot. Once accepted, edit the contract here by reviewed PR; put status/proof receipts, bounded implementation tickets, and delivery dependencies on GitHub issues. Do not maintain a second evolving specification in #502.

## Read by question

| If you need to understand... | Read |
| --- | --- |
| Why this exists, product destination, all 40 Operator user stories | [Product destination and user stories](product-and-user-stories.md) |
| Governing modules, Standing Authority, coherent portfolio selection, shared work | [Strategy and Allocation](strategy-and-allocation.md) — C01–C02 |
| Observation Demands, API budget, durable MutationAttempts and Safety Fences | [Evidence and Execution](evidence-and-execution.md) — C03–C04 |
| Economic decisions, bounded Marketplace coverage, Neutral Wait and stalled progress | [Economics and Coverage](economics-and-coverage.md) — C05–C06 |
| Server Reset and restart recovery, all autonomous API capabilities | [Lifecycle and Capability](lifecycle-and-capability.md) — C07–C08 |
| Mission Control, truthful economics, calibration, qualification gates, tests, acceptance and out-of-scope | [Experience and Qualification](experience-and-qualification.md) — C09–C12 and completion criteria |
| Possible economic-first simplification and multi-Ship collaboration, **not yet accepted contract changes** | [Economic-first exploration](economic-first-exploration.md) |

## Status and dependencies

- **Canonical tracking and proof receipts:** [#502](https://github.com/bturney/spacetraders/issues/502); read its *latest* qualified frontier rather than trusting a static status copied into documentation.
- **Accepted architecture:** [ADR 0010](../adr/0010-autonomous-runtime.md), with the other accepted ADRs named by #502, and [GLOSSARY.md](../../GLOSSARY.md). The source-controlled contract does not silently overrule those decisions.
- **Actual-bot accelerated simulator:** [#677](https://github.com/bturney/spacetraders/issues/677) is an independently approved design and implementation frontier; this migration neither changes that specification nor authorizes experiments/deployment.
- **Operator information architecture:** [#311](https://github.com/bturney/spacetraders/issues/311) and its accepted design decisions remain in force until explicitly reconsidered.

## How to change the design

Preserve original Operator intent and causal decisions. Amend the smallest owning contract, state what requirement or acceptance proof changes, and link the applicable issue or decision. Mark new ideas as hypotheses until approved; do not quietly broaden a current implementation ticket. Maintain the #502 rule that a contract is **proven, violated, or unproven** by real evidence, never by the existence of a class, passing isolated tests, or closing an issue.
