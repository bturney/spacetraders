# Autonomous Fleet architecture and invariants

This is the **orientation map** for implementation. Accepted ADRs and current source supply the detailed contract; this file identifies the owning seam and evidence required before changing it.

## One decision chain

| Owner | Responsibility | Boundary |
| --- | --- | --- |
| Fleet Strategy / Fleet Generation | Policy revision and current game-generation authority | A Revision expresses intent; a reset creates new game identity, never rewrites old receipts. [ADR 0015](../adr/0015-single-operator-single-current-agent.md). |
| Fleet Planning | Propose outcome-specific contributions, costs, dependencies, uncertainty and information needs | Planning proposes; it does not publish competing portfolios. |
| Fleet Allocation | Compare, retain, claim and publish coherent Fleet work | **One** authority for the current portfolio. Claims exclude exclusive work; Reservations protect fungible exposure; Pledges represent divisible fulfillment. Revision/version checks and bounded replacement preserve independent work. |
| Evidence / Operational Intelligence | Acquire and retain contextual observations via typed demands | Unknown and stale are first-class states. One relevant observation can satisfy compatible demands. Returned mutation state is reused rather than reflexively re-read. |
| API Capacity Governor | Admit and prioritize scarce requests; protect safety/recovery and live usefulness | Admission is distinct from protocol rate limiting and from economic candidate valuation. A deferred request is not a lack of work. |
| Ship Execution / Fleet execution | Carry out accepted root Intents, wait and reconcile | An executor follows current Fleet authority. It does not become a second allocator. |
| MutationAttempts | **Sole durable authority** for whether a mutation was accepted, absent or remains ambiguous | Prepare before send, reconcile uncertain effects from authoritative evidence, fence dependent work and never blindly repeat a non-idempotent action. See [ADR 0011](../adr/0011-single-recovery-authority-for-mutations.md). |
| Decision Episodes / Earnings / projections | Explain why work won, what happened and how estimates compare | Causal source receipts stay intact. A read model does not decide whether a mutation happened. [#757](https://github.com/bturney/spacetraders/issues/757) is replacing legacy trade projections with durable Earnings. |

[ADR 0010](../adr/0010-autonomous-runtime.md) is the governing modular-monolith baseline; [ADR 0007](../adr/0007-game-truth-and-quality-of-life-guardrails.md) governs game truth. [GLOSSARY.md](../../GLOSSARY.md) owns terms. Compare this orientation map with **current source**, especially when a newer branch is not yet merged.

## Important accepted refinements

**Acquisition is not a generic auction yet.** Gate 2C [PR #737](https://github.com/bturney/spacetraders/pull/737) and [ADR 0016](../adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md) added a *surplus-first* Capacity Investment after the Market decision, into the same versioned Fleet portfolio. An enabled-value estimate spans a Generation Horizon; a whole-horizon purchase does not directly displace today's trade through a universal score. Cross-horizon auctioning is deferred pending comparative evidence.

**Waiting is deliberate.** [ADR 0012](../adr/0012-neutral-wait-contract.md) assigns Fleet Allocation one Neutral Wait mint site; absent worthwhile candidates plus a future durable Observation Demand are required. Unknown capability, API Capacity Deferral and genuine infeasibility retain their own distinctions. Updating a wait must not erase original selection evidence.

**No human rescue path.** [ADR 0017](../adr/0017-nothing-needs-the-operator.md) supersedes old requirements for Attention/Intervention, Ship Reservation and in-app Emergency Stop. Plan Health expresses a limitation; the Operator is not issued a gameplay task. Stopping the service is the kill switch; game-flight consequences and mutation recovery still hold.

## Invariants to preserve while simplifying

1. Each gameplay mutation has current Generation/Revision authority, an owning Intent or Fleet-level action and a durable before-send attempt; the remote server, not a projection, settles ambiguous effects.
2. Only the selected Fleet allocation may commit Ships, credits, Cargo and shared fulfillment; no other independent planning/execution loop can double-spend or monopolize another Ship.
3. A failed or unknown dependent step fences *its own* unsafe subgraph, while unrelated admissible work continues.
4. Game-state observations carry provenance, freshness and Generation; **unknown is not zero, false or negative profitability**.
5. Resets fence predecessor actions and preserve historical attribution; a process restart recovers within the current Generation.
6. API throughput is a scarce resource without bypassing governed admission, protocol limits or durable retry safety.
7. Estimated economics and realized Earnings remain distinguishable; every material allocation result has reconstructable why/why-not evidence.

For a new capability, identify the existing owner, the needed proof, and which invariant it could violate **before** adding a schema, durable writer or scheduler. Prefer deletion/consolidation when two paths own the same fact.
