# Economic-first exploration: simplifying the Fleet engine

**Status: design exploration, not an amendment to the accepted #502 contracts or the accepted #677 simulator handoff.** This captures the Operator's 2026-10-18 direction after comparing this engine with the forked Erlang economic agent. Nothing here authorizes removing existing runtime protection, changing a live Strategy, or deploying a different controller. Validate and explicitly choose a revised contract before implementation.

## Product hypothesis

SpaceTraders is predominantly an economic optimization game. The **first fun mode** may be an autonomous default policy that maximizes realized economic output over the available Fleet Generation horizon, rather than asking the Operator to frequently modify Strategic Objectives. The Operator can later explore alternative economic policies and simple levers; the value of a configurable Strategy cockpit is not yet established.

This changes the *product's intended default policy*, not the authority of the game API or the need to halt unsafe mutations. For now, evaluate whether a fixed built-in Strategy could be represented by the existing revision record while the user-facing control surface is simplified. Do not assume deleting Fleet Strategy or stored revisions is necessary.

Questions to settle through observation and explicit Operator choice:

- Is the optimization target net attributable earnings, ending wealth, return per constrained Ship-hour/API request, a reset-horizon utility, or a multi-metric portfolio? Measure trade-offs, not just credit balance.
- Which achievements remain objectives versus instruments that produce future economic value: gate construction, chart rewards, discovering profitable markets, Ship growth, and coordinated supply chains?
- Can one built-in policy with a few disclosed risk limits reproduce useful autonomous decisions without frequent human adjustment?
- Which future alternate modes would actually be fun to compare (for example, economic growth, gate-first, charting/exploration), without building a general policy editor now?

## A lean controller hypothesis

Keep **one** logical decision loop from evidence/belief through candidate valuation, one coherent Fleet allocation, bounded outcome execution, and measurement/learning. All work—trading, observation, preparation, acquisition, retained work, and multi-Ship cooperation—must be comparable or deliberately protected under that same allocation decision.

The economic planner should value expected marginal contribution over the remaining time, including uncertainty, price/market depth, fuel, cargo, travel, capital, switching, API capacity, and information acquisition. "Unknown" is not "bad" or zero. Use bounded initial estimates, record every admissible rejected alternative, and correlate predicted versus realized outcomes. API capacity becomes an economically priced bottleneck **in addition to** protocol safety and protected recovery service, not an independent scheduler that overrides the allocation.

## What is worth retaining while deleting complexity

The question is not whether 20% of code can be exactly 80% as correct; that ratio has no evidence yet. Distinguish inexpensive accidental complexity from narrow safeguards against genuinely costly, irreversible consequences.

**Proposed non-negotiable invariants for any simplification experiment:**

1. No new gameplay mutation without current runtime authority and a functioning Emergency Stop.
2. One owner per selected outcome; never double-claim a Ship, credits, Cargo, or shared fulfillment.
3. An ambiguous non-idempotent mutation is not blindly retried. Durable attempt evidence must survive before bytes can leave, and recovery reconciles authoritative effects.
4. Reset identity and old-generation work cannot authorize a new world; a software restart is not a game reset.
5. One uncertain Ship or dependency must not stall unrelated admissible Fleet work.
6. The system never promotes missing data or simulator assumptions into authoritative game truth.

**Candidates for simplification, to test rather than assume:** duplicate orchestration paths; version/translation layers that do not guard an actual concurrency boundary; multiple projections of the same fact; redundant durable records; capability-specific allocation; an over-configurable Strategy UI; and repeated read/retry choreography owned by callers. A simpler schema is possible, consistent with the Operator's 2026-10-17 #502 decision, but migration must not erase unresolved mutation evidence merely to make the new model look clean.

Evaluate deletion by counting independent decision owners, duplicated state transitions, write authorities, call paths, database tables/columns, and observable failure classes—not only lines of code.

## Multi-Ship work is a core requirement, not optional sophistication

A single Candidate Contribution may describe a jointly useful Fleet-level outcome with several Ship roles (for example, producer plus hauler, or scout plus transport). Allocation should decide the group **as a unit**: claim multiple Ships, bound credits/Cargo/receiving capacity, define dependencies and fulfillment pledges, and permit unrelated Ships to proceed. Each Ship executes a bounded outcome, while allocation owns the coordinated result and smallest safe replan. Do **not** build competing autonomous team planners or let workers silently negotiate a second allocation.

The smallest useful proof has two cooperating Ships, one shared deliverable, one retained independent activity, and a deliberate interruption that replans only the affected dependency subgraph.

## Proposed experiment and decision sequence

1. **Baseline reality.** Preserve #502 C04 correctness proof and capture actual economic throughput, API-cost attribution, stalled/idle causes, alternative candidates, and operator effort. A simplified design must be compared with demonstrated behavior, not with a hoped-for baseline.
2. **Default economic policy.** In a separate, explicitly chosen policy variant, make trading, discovery, construction, acquisition and support work contend on one decision plane. Keep accepted revision and safety semantics until their replacement is proven and approved.
3. **Falsify economic models.** Use rejected-alternative records and paired variants to test valuation and opportunity-cost hypotheses. An impressive score is not a realized gain.
4. **Run actual-bot experiments under #677.** Preserve the accepted real-HTTP, real application, isolated PostgreSQL and finite experiment-envelope design. First demonstrate fidelity of the relevant economics; distinguish controlled-simulation ranking from live predictive proof. #677's gate-focused and multi-objective families remain accepted until changed explicitly.
5. **Reduce architecture only with evidence.** Delete or merge machinery whose role is redundant, while testing uncertainty, crash windows, resets and simultaneous multi-Ship work. Prefer the smallest coherent implementation, not a second framework layered over the first.
6. **Reconsider Operator levers after trials.** Choose what control actually creates a better game experience. An economic default may require fewer user-facing settings, even if preserving a durable policy identity internally remains useful.

## Relationship to accepted work

These are ideas to evaluate, not revised C01–C12 acceptance criteria. In particular, #502's currently accepted Operator-owned immutable Strategy and C09 experience cannot be dropped just because an economic default seems appealing. #677 explicitly retains actual Fleet Strategy and authority in its qualified experiments. Reconcile those choices in a focused decision before modifying either contract. The in-repo documents remain the source of the accepted design after this migration; this page remains exploratory until the Operator approves a concrete replacement.
