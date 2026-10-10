# One recovery authority per mutation

**Status:** accepted

`SpaceTraders.MutationAttempts` is the sole durable record of whether a gameplay
mutation happened, is still ambiguous, or was proven absent. A mutation owner
reconciles its attempt from the narrowest authoritative resource and then
derives whatever narrative it needs from that attempt's outcomes. It does not
write a second copy of the same fact into its own bookkeeping — including
`StrategyDecisionEpisode.actual_outcomes`, which is a projection of reconciled
attempts rather than an independent writer.

Fleet acquisition was the first case to get this wrong: it wrote a `"purchase"`
key into the Decision Episode alongside the attempt, so two records claimed the
same fact and either could be read as authoritative. A future reader would
reasonably have "fixed" the episode by hand and desynchronized it from the
attempt. Reconcile the attempt, then describe it.

Consequences:

- Recovery code reads `MutationAttempts`, never domain bookkeeping, to decide
  whether a mutation is unresolved.
- Reconciling a mutation must satisfy the operation's declared
  `fence_dependencies`. `purchase-ship` fences on `owned_fleet` and
  `agent_credits`, so its reconciliation must present authoritative
  observations covering both keys; inferring a purchase by diffing the owned
  Fleet against registered Ships is not sufficient evidence.
- A Decision Episode explains a decision by referencing reconciled attempts, so
  explanation and recovery cannot disagree.
- When a new mutation owner is added, it reuses this authority rather than
  extending the pattern that preceded it.

Bounded deviation (issue 662): Market trade progress
(`SpaceTraders.FleetAllocation.TradeProgress`) reads transaction receipts from
the completed buy/sell Intent's `last_action_result`, because a succeeded
`purchase-cargo`/`sell-cargo` attempt outcome retains only status and nav
evidence, not the transaction. The Intent is completed only after its attempt is
reconciled, and each receipt carries the Intent's `mutation_attempt_id` as the
link. The projection is re-derived on every read and never decides recovery.
Retaining the transaction in the attempt outcome would remove the deviation.

Related: [ADR 0010](0010-autonomous-runtime.md) assigns each mutation exactly
one owner; this record assigns each mutation exactly one recovery record.
