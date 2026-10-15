# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Before exploring

Read the repo-root `GLOSSARY.md`, then read the ADRs in `docs/adr/` that touch the area of work.

## Supplemental Fleet Strategy examples

For bounded Fleet allocation, economic-decision and multi-Ship behavior,
[strategic reasoning scenarios](strategic-reasoning-scenarios.md) give
non-normative, hypothetical proof cases. Treat issue #502, the Glossary, and
relevant ADRs as authority; recheck repository behavior before adopting an
example. For related Operator-facing explanation and calibration gaps, see
[strategic observability and UX](strategic-observability-ux-gaps.md).
Consult them when relevant to an already-authorized scope, not as a separate
implementation backlog.

## Fleet decision pipeline

Map of who does what at an evidence boundary; read the modules for how.

- **Wake**: `FleetAllocation.Reconciler` — evidence PubSub, due Observation Demands, 60 s durable sweep; calls each owner in order.
- **Market domain**: `FleetAllocation.MarketDomain.reconcile/5` — trade + coverage + retained work, one decision per boundary.
- **Propose**: `FleetPlanning` (+ `FleetIntelligence`, `FleetShadow`) → Candidate Contributions; never selects.
- **Select/publish**: `FleetAllocation` — `select_portfolio`, `publish_portfolio`, `replan_subgraph`; sole portfolio authority (ADR 0010).
- **Pursue**: `FleetExecution` activates one Commitment's root Intent.
- **Spend/recover**: `CreditSpending` admits credits (ADR 0013); `MutationAttempts` sole recovery authority (ADR 0011).
- **Capability owners** (`FleetAcquisition`, `FleetContracts`, `FleetConstruction`, `FleetResources`, `FleetRefit`) reconcile beside the Market domain; Gate 2C (#730) moves acquisition selection into Fleet Allocation (ADR 0016).

## Use the glossary's vocabulary

Current Fleet authority: `FleetGeneration.current_fleet/0,1` (ADR 0015).
Scope authenticates; Agent/Generation ids bind resources and causal history.
`operator_id` on domain rows is retained authorship, not an ownership association.
Legacy adoption occurs only during actual migration; boot preflight validates,
never manufactures authority from raw Agent inserts.

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `GLOSSARY.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR, surface it explicitly rather than silently overriding:

> _Contradicts ADR-0004 (LiveView as the control surface, no CLI) — but worth
> reopening because…_
