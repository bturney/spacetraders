# Evidence, API capacity and execution recovery

> Imported from [#502](https://github.com/bturney/spacetraders/issues/502) on 2026-10-18. The contract text below is preserved from that issue without semantic edits. Qualification status is tracked separately; a written contract is not proof of implementation.

### C03 — Shared evidence and scarce API capacity

Every observation satisfies a typed, revocable demand through the existing governing interface. Every mutation uses the same admission authority. Facts retain subject, Generation, observation time, source, validity, and causal context. Returned mutation state is reused immediately; unreturned facts are not invented. Contextual owned-entity reconciliation is distinct from optimization refresh.

Compatible demands share observations. Each future demand has durable earliest useful timing; deadlines do not silently erase missed work. Changing Strategy or relevance withdraws obsolete demands. Boot reconstructs due work and safe re-evaluation from durable state. Process timers and PubSub are disposable wakeups, never the only route to progress.

Freshness is fact- and decision-specific rather than duplicated global five-minute rules. Stable identity/location facts, volatile Listings, safety checks, and post-mutation reconciliation have different conditions. Raw protocol limits protect both Agent-specific and shared-egress capacity; they do not substitute for strategic admission. Safety/reconciliation and deadline-critical work are protected, ordinary work gets service when safe, and sustained 429s or service delay become visible backpressure. Outages retain current demand and recover at a sustainable rate without replay bursts.

### C04 — Truly durable mutation and recovery protocol

MutationAttempts remains the single recovery authority. Intent progress and Decision Episode actual outcomes refer to or derive from it; they are not independent writers of whether an action happened.

| Boundary | Required durable result and recovery behavior |
| --- | --- |
| Before dispatch may become possible | The owning outcome, selected action identity/fingerprint, Generation, authority, precondition evidence, consequences, dependencies, and prepared attempt are committed and linked. No in-flight claim of an action may exist without its attempt. |
| Immediately before network dispatch | Sent-or-unknown is committed and current authority revalidated before bytes may leave. A nested transaction returning successfully is not proof that an enclosing transaction committed. |
| Response or response loss | Authoritative response state and outcome are recorded, or unresolved evidence remains. Process death, persistence failure, timeout, and lost response use the same recoverable protocol. |
| Reconciliation | Observe the narrowest authoritative resources covering the operation's declared dependent effects; classify accepted, absent, or conservatively bounded unknown. Missing, stale, malformed, or failed evidence cannot advance or clear the fence. |
| Further work | Continue confirmed success; retry proven absence only if still selected and authorized; otherwise retain bounded uncertainty or safely replan. New requests get traceable attempt identity and cannot blindly replay the old request. |

Network dispatch must not be inside a caller's uncommitted database transaction. Locks and short transactions may establish durable ownership and work, but a durable transition must survive the caller dying anywhere in the send window. Tests must observe this from an independent database connection or restarted runtime, not merely through the caller's transaction.

Root Intent execution requires authoritative owned-entity evidence appropriate to the transition. Failed owned-state acquisition yields waiting, scoped degradation, or a genuine safety condition; it never fabricates empty or nil state. Ordinary infeasibility returns to allocation. Narrow Safety Fences preserve affected reservations and dependents while unrelated admissible work continues. Internal recovery cannot rewrite uncertain history to make invariants appear true.
