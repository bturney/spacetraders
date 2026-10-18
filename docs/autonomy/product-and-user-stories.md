# Product destination and user stories

> Imported from [#502](https://github.com/bturney/spacetraders/issues/502) on 2026-10-18. The contract text below is preserved from that issue without semantic edits. Qualification status is tracked separately; a written contract is not proof of implementation.

## Problem Statement

The autonomous runtime has accumulated many completed implementation tickets, overlapping follow-on specifications, and production fixes without establishing that the Fleet reliably turns an Operator's Strategy into useful outcomes. Activity can look healthy while the Fleet spends its resources observing indefinitely, unrelated Ships are prevented from working, acquisition never competes with existing work, or interrupted mutations leave permanently stalled Intents.

The Operator cannot confidently tell whether a limitation is an intentional tradeoff, missing evidence, or broken execution. Maintainers have a growing patch backlog instead of a small, coherent design whose invariants can be understood and proved.

The Operator has explicitly requested ticket bankruptcy for the **autonomous-runtime backlog only**. This specification replaces that delivery backlog. Administrative closure of old work means **superseded, not fixed**. Existing code, completed infrastructure, decision history, and defect evidence remain available; completed ticket counts are not evidence that the product meets its destination.

## Solution

Recover and complete the product described by [Reset-to-reset autonomous strategy — Phase 4+ map](https://github.com/bturney/spacetraders/issues/297). Preserve its decisions and validated Operator experience. Replace the old eighteen-phase migration checklist with a contract-led recovery route appropriate to an already substantially implemented application.

The Operator sets an immutable, reset-spanning Fleet Strategy. The system deterministically plans and reconciles a coherent Fleet portfolio, executes bounded outcomes under exclusive authority, acquires decision-relevant evidence economically, recovers through crashes and Server Resets, and asks for the Operator only at the accepted external-authority boundary. Mission Control explains actual progress and genuine limitations through calm, truthful, outcome-first views.

Retain implementation that satisfies the contracts below. Refactor implementation whose authority or knowledge leaks across callers. Replace implementation that cannot be made to satisfy its contract cleanly. Reuse PostgreSQL, BEAM, Phoenix authentication, generated API inventory, durable records, and the scenario harness where they earn their place; neither compatibility nor a presumed rewrite determines the result.

**Destination:** complete autonomous ownership of the pinned API, useful and adaptive Fleet behavior, the agreed desktop/phone Operator experience, and auditable multi-day reset-to-reset operation under failures. Repairing the current trading stall alone does not complete this specification.

## User Stories

### Strategy and authority

1. As an Operator, I want to declare ordered outcome-level Strategic Objectives, so that the system chooses methods and Ship assignments for me.
2. As an Operator, I want attain, maintain, and continuous objectives with explicit scope and evaluation, so that progress means the outcome I actually selected.
3. As an Operator, I want Hard Constraints distinguished from Preferences and unenforceable guarantees rejected, so that the system does not promise protection it cannot provide.
4. As an Operator, I want transparent presets, durable drafts, exact revision comparisons, and deliberate activation, so that recommendations or product updates never silently change my intent.
5. As an Operator, I want a durable Emergency Stop and explicit fresh-plan resume, so that every new mutation, including replacement minting, remains under my authority.

### Coherent Fleet work

6. As an Operator, I want the Fleet to compare direct work, evidence gathering, preparation, and acquisition together, so that callback order cannot determine what wins.
7. As an Operator, I want higher Strategic Priorities protected without unnecessarily excluding lower-priority work, so that independent Ships and spare resources remain productive.
8. As an Operator, I want compatible Commitments retained while the affected dependency subgraph is replanned, so that one changing opportunity does not discard useful Fleet work.
9. As an Operator, I want Claims, Reservations, and Pledges backed by current evidence, so that resources and shared fulfillment cannot be double-counted.
10. As an Operator, I want Ship acquisition evaluated while useful work is active, so that the Fleet can grow without waiting for its entire portfolio to disappear.

### Evidence and economics

11. As an Operator, I want bounded baseline Marketplace coverage across discovered Systems, so that distant opportunities are not rejected merely because their first observation has no standalone profit.
12. As an Operator, I want an admissible profitable route discovered from partial evidence to be pursued promptly, so that completing an observation portfolio is not a global barrier to action.
13. As an Operator, I want incomplete or unreachable coverage distinguished from an unprofitable decision surface, so that missing facts cannot justify a false negative conclusion.
14. As an Operator, I want observation, travel, fuel, market depth, capital, and API cost reflected in decisions, so that the system does not spend indefinitely looking or trade away its own expected return.
15. As an Operator, I want contextual freshness and durable future Observation Demands, so that useful evidence is shared and refreshed when needed instead of repeatedly polling every entity.

### Execution and recovery

16. As an Operator, I want one root Intent per claimed Ship to own prerequisite choreography, so that callers request an outcome rather than assemble a fragile action script.
17. As an Operator, I want mutation evidence committed before a request can leave, so that interrupted dispatch is recoverable even if a process or VM dies.
18. As an Operator, I want ambiguous mutations reconciled against authoritative effects before any dependent retry, so that missing responses cannot duplicate consequences or become permanent unexplained stalls.
19. As an Operator, I want absent actions retried only while still selected and authorized, so that recovery never resumes obsolete work.
20. As an Operator, I want the smallest necessary Safety Fence with independent continuation and sustainable recovery, so that one uncertain Ship or capability does not stop the Fleet.

### Lifecycle and complete capability

21. As an Operator, I want my Strategy to survive Server Resets while world-scoped state does not, so that replacement operation uses the new game's actual resources.
22. As an Operator, I want definitive reset evidence to fence old work, mint a permitted replacement, bootstrap, and resume automatically, so that continuity does not require routine attention.
23. As an Operator, I want restart and deploy recovery from durable records without a Fleet Generation transition, so that software lifecycle does not distort game history.
24. As an Operator, I want every exposed API action available autonomously when strategically relevant and admissible, so that a manifest entry is not mistaken for a usable capability.
25. As an Operator, I want Contracts, Construction, producer-hauler work, resources, readiness, repair, scrapping, and inter-System operation to share the same allocation and recovery rules, so that capability growth does not add competing authorities.

### Understanding the operation

26. As an Operator, I want Mission Control to answer whether operation is healthy, objectives are succeeding, the Fleet is contributing, and I am needed within 30–60 seconds, so that routine monitoring stays simple.
27. As an Operator, I want healthy progress, Neutral Wait, unknown availability, capacity deferral, objective infeasibility, Degraded Operation, and Intervention distinguished, so that busy processes and stationary Ships do not create misleading health claims.
28. As an Operator, I want Unallocated Ships linked to the applicable decision and future evidence time, so that unused capacity has a defensible explanation.
29. As an Operator, I want durable Attention when progress has genuinely broken its expected recovery or re-evaluation contract, so that a stalled Fleet cannot remain silently healthy.
30. As an Operator, I want concise reasons with retained alternatives and evidence available on demand, so that explanations and recovery cannot disagree about what happened.

### Complete Operator experience

31. As an Operator, I want Mission Control, Operations, World, and Strategy as the four primary destinations, so that navigation follows my recurring tasks rather than API resources.
32. As an Operator, I want objective-grouped Endeavors and purpose-first Ship views, so that work, contributing Ships, dependencies, journeys, and exceptional interventions stay connected to Strategy.
33. As an Operator, I want linked Atlas and Intelligence, truthful Transit Routes, contextual entity pages, and local-first search, so that spatial inspection does not create uncontrolled API demand.
34. As an Operator, I want Activity, Generations, acknowledgement separate from resolution, and comparable history, so that consequential events remain understandable across resets.
35. As an Operator, I want common monitoring and Strategy refinement usable on a phone with stable live updates and drafts, so that refreshing data never overwrites what I am doing.

### Proof and optimization

36. As an Operator, I want realized economics distinguished from estimates, costs attributed to outcomes, and telemetry gaps shown as unknown, so that an attractive dashboard does not fabricate success.
37. As a maintainer, I want bounded, versioned, reversible calibration that cannot edit Operator intent, so that better models remain inside accepted authority.
38. As a maintainer, I want tests through the real runtime and Operator interfaces, so that separately working planners and executors cannot hide a broken operating loop.
39. As a maintainer, I want a traceable contract/proof baseline and a small current delivery frontier, so that historical tickets do not dictate architecture or generate another unmanageable backlog.
40. As an Operator, I want an approved multi-day trial and an honest evidence handoff, so that completion means demonstrated unattended operation rather than another declaration of readiness.
