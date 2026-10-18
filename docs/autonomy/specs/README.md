# Capability specifications

**The accepted, durable behavior contract for each new capability belongs here.** Keep one scoped file per coherent outcome, e.g. `market-information-value.md` or `producer-hauler-coordination.md`, when (and only when) that design is approved. This directory starts without speculative future specs.

An implementation issue links the accepted **file and commit**, holds bounded tasks and proof receipts, and closes. Revisions to the product contract are reviewed edits to that file and, where architectural authority changes, an ADR. Prior decisions remain inspectable in Git history. The [roadmap](../roadmap.md) owns sequencing; the [capability ledger](../capabilities.md) owns status and coverage.

## Copy for an approved capability

```markdown
# <Capability and outcome>

Status: Proposed | Accepted | Integrating | Implemented | Qualified | Superseded
Decision: <accepted Operator decision or ADR; otherwise Proposed>
Owner: <existing Fleet module/one decision authority>
Related roadmap goal: <link>
Source baseline: <commit + targeted code paths>
Replaces: <older spec/issue or none>

## Problem and desired outcome
<Observed failure/opportunity, source, measurable outcome, binding resource.>

## Chosen behavior
<What Fleet can select/execute/observe, limits, dependencies, alternatives and unknowns.>
<What other modules may rely on; special reset/ambiguity/resource rules.>

## Rejected alternatives and scope
<Trade-offs, deliberate omissions, consequences.>

## Decisive proof
<Setup, actual runtime/HTTP boundary, distinct failure scenarios and expected receipts.>
<What can be proven in local tests, simulator (with fidelity qualifier), and live game.>
<What evidence is still unknown, and what constitutes pass/fail/inconclusive.>

## Delivery / qualification record
<PRs, committed source, pinned test and actual-game/simulator receipts, residuals.>
```

**Acceptance criterion:** an implementer can find the existing owner and independently reproduce the stated outcome proof without expanding into another backlog. A test that only constructs data or a simulation that cannot model the alternative does not qualify live behavior.
