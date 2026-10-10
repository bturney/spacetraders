# One Neutral Wait mint site and one current wait per allocation scope

Status: Accepted

Date: 2026-09-28

## Context

Issue 487 defines the Neutral Wait contract before issues 488, 489, 490, and 491
implement it. `GLOSSARY.md` defines Neutral Wait as a deliberate Fleet Allocation
result: no worthwhile admissible Candidate Contribution exists, and the evidence
needed for re-evaluation has a durable future Observation Demand. Three look-alike
conditions must never manufacture one: unknown Governed Availability, API-capacity
deferral, and objective infeasibility. Without a single mint site, those conditions
can leak into the wait and make Attention meaningless.

## Decision

One condition pair may establish a Neutral Wait, evaluated only inside Fleet
Allocation reconciliation:

1. Planning returned zero worthwhile admissible Candidate Contributions for the
   Fleet Commitment portfolio, and
2. At least one durable Observation Demand exists with a future due time
   (earliest useful observation time), so the wait knows when re-evaluation can
   next change its mind.

No other code path mints a Neutral Wait. Producers of unknown availability and
API-capacity deferral report their own dispositions and stay invisible to this
boundary; objective infeasibility is a distinct Strategy Decision Episode outcome,
never a Neutral Wait. Tests prove the negative cases by exercising those producers
directly and asserting that no Neutral Wait episode results.

A Neutral Wait is one Strategy Decision Episode held open by equivalence, not a
sequence of episodes. One current wait exists per Operator + Fleet Generation +
active Fleet Strategy Revision (portfolio scope, not per Strategic Objective).
Equivalence holds while the selected result (none) and the binding limitation kind
are unchanged: those reconciliations refresh the current episode's evidence, next
observation time, and candidate records in place. Supersession happens on: a
changed Fleet Strategy Revision (including Strategic Priority-only edits inside a
revision), a changed Fleet Generation, a changed limitation kind, or a selected
plan. A superseded episode keeps its identity; the new result starts a fresh
episode.

The durable representation gives `StrategyDecisionEpisode` a selection kind
(`selected_plan` or `neutral_wait`) plus neutral-specific fields: binding
limitation kind and next observation time. A small pointer table per Fleet
Generation holds the current allocation result for O(1) lookup of "is the fleet
waiting right now". The pointer references the episode and copies no facts (ADR
0011 rule: one authority per fact).

Amended 2026-10-10 (issue 662): a decision that Fleet Allocation selected but
then refused to publish is also durable decision evidence. Its episode carries a
third episode kind, `publication_rejected`, with a bounded rejection reason. It is
not a selection kind: the pointer never references it, and the current allocation
result stays `selected_plan` or `neutral_wait`. Recording the refusal as its own
kind keeps it from being read as a selected plan that never ran or as a wait.

Metrics use a closed limitation kind vocabulary: `incomplete_coverage`,
`no_admissible_candidate`, `below_economic_threshold`,
`awaiting_scheduled_evidence`. Identity-rich detail (candidates, rejections,
evidence references, Ship, demand, and episode identities) lives in durable
evidence and structured logs or traces, never as metric labels.

Mission Control shows exactly five facts on the summary surface: the fixed phrase
`no worthwhile admissible contribution`, the limitation kind, coverage
completed/required when the limitation is `incomplete_coverage`, last evaluation
time, and next due time. Identity links render only on click-through into
evidence. An `Unallocated` Ship (read-projection state: registered, no active
Claim) during a Neutral Wait carries a causal link to the wait's Decision
Episode. `Attention` never fires for a Neutral Wait or for capacity deferral; it
summarizes objective infeasibility, Degraded Operation, and Intervention.

## Consequences

- The False Negative Conclusion work in issue 484 is also a Truth Maintenance
  safety property: a System-wide negative conclusion is only provable after
  coverage is complete, so `incomplete_coverage` waits cannot silently mask an
  unprofitable System.
- The Strategy Decision Episode schema changes in issues 488–491 are additive;
  the selection-kind field and pointer table are their shared contract, fixed here
  before implementation.
- Calibration values and economic switching formulas stay out of scope; the
  threshold limitation kind exists, but which threshold fires it is decided
  elsewhere.
