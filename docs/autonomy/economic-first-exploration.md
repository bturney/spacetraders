# Economic-first Fleet policy — exploration

**Status:** Operator direction recorded 2026-10-18, **not** an approved replacement for #502, [ADR 0016](../adr/0016-ship-acquisition-is-surplus-first-capacity-investment.md), [ADR 0017](../adr/0017-nothing-needs-the-operator.md) or [#677](https://github.com/bturney/spacetraders/issues/677). [Roadmap](README.md) gives the current implementation owners. This note is a set of hypotheses to falsify, not a work queue.

## Hypothesis

The fun may be **watching an economically effective autonomous Fleet**, then comparing different policies, rather than frequently hand-editing Fleet Strategy. Try an economic-growth default first, with future levers only where experiments show an interesting trade-off. This is a policy/product question; it does not by itself justify deleting the existing Strategy revision identity, execution authority or recovered evidence.

## Use work already in flight

- **#715 is complete:** Market reconciliation and retained World reads were simplified; measure new deletion candidates against those merged changes.
- **Gate 2C is merged:** #730 / PR #737 and ADR 0016 already value a Ship purchase as conditional, surplus-first Capacity Investment over a Generation Horizon. It runs *after* the Market decision, not inside a universal economic auction. Compare that deliberate trade-off before proposing a new allocator.
- **#757 is the current economic/UX increment:** #763 adds estimated **net credits per Ship-hour** to trade selection and acquisition; #766 records completed-trade Earnings. These are on the #802 integration path until cutover #776—not necessarily on `main`.
- **#677 is the accepted test harness:** #801 integrates the actual bot with the private HTTP simulator, not a replacement bot policy. Comparison conclusions remain conditional on gameplay/economic fidelity. The approved finite comparison limits and paired scenarios apply.

## Choices to test

1. **Economic target.** Compare realized attributable Net Earnings, end-of-Generation wealth, and marginal return per Ship-hour / scarce API request. State whether Gate construction, charting and exploration are rewarded outcomes or investments whose value is future growth. A credit balance alone is not Net Earnings.
2. **Bounded uncertainty.** Price market depth, travel, fuel, capital, switching, evidence freshness, reset horizon and API pressure. A missing observation is **unknown**, not zero value or negative evidence. Preserve the Governor's protected recovery and protocol limits while valuing optional observations economically.
3. **One Fleet portfolio.** Compare useful direct work, observation, preparation, retention and acquisition at the owning Allocation seam. Measure whether ADR 0016's simple surplus-first purchase rule loses meaningful value before paying for a common cross-horizon score.
4. **Multi-Ship teams.** One contribution may require producer + hauler or scout + support, selected and reserved **as a group**. Allocate claims, divisible fulfillment and shared resources once; Ship execution remains per-Ship. Prove two cooperating Ships, an independent Ship continuing, and dependency-scoped interruption/replan before generalizing.
5. **Less machinery.** Count duplicate decision authorities, overlapping state, tables, handoffs and recovery paths. Remove a layer only if tests preserve accepted game/reset identity, single-writer resource ownership, durable before-send mutation evidence, ambiguous-effect reconciliation and unrelated-Ship progress. Under ADR 0017 the kill switch is stopping the service, **not** a persisted Emergency Stop flag.

## Evidence before changing the accepted policy

1. **Baseline:** obtain actual completed Earnings and estimation error from #757; record stalled/idle work, API cost, acquisition refusals and alternative candidates. The measurement must separate absent evidence from real zero performance.
2. **Variants:** use #677's approved actual-bot, real-HTTP isolated worlds and unchanged experimental authority. Run paired policies within an explicitly approved finite manifest. Distinguish simulator scenario correctness, economic credibility, wall-clock throughput and live predictive validity.
3. **Decision:** identify a reproducible improvement, counterexamples, resource cost, and trade-offs that affect the *fun* of the game. If evidence is inadequate, record **inconclusive** rather than ship new Strategy knobs.
4. **Approved change:** amend the owning ADR/spec and its acceptance evidence, then implement in the current responsible module. Preserve retained game authority and causal records while simplifying.

**Done for this exploration** means a reviewed decision that says whether to adopt an economic default, which existing policy and UI controls change, what proof supports it, and what remains unproven. An essay or benchmark score alone does not close it.
