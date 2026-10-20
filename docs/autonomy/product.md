# Product contract: an economically intelligent Fleet worth watching

## North star

SpaceTraders is primarily an economics and resource-allocation game. Build a Fleet that plays autonomously from mint through Server Reset, turns scarce credits, Ship time, Cargo, information and API capacity into **useful outcomes**, and exposes enough causal and economic evidence that an Operator can enjoy watching it and compare different approaches.

**Autonomy:** The machine selects Ships, methods and timing. The single Operator is not asked to play manually or rescue routine stalls. The product can report that it is stuck or off plan without turning that into a request for human gameplay. See [ADR 0017](../adr/0017-nothing-needs-the-operator.md). Stopping the service is the accepted kill switch.

**Capability before optimization:** Build useful economic, charting, construction/logistics and cooperative Fleet behaviors before running large strategy-optimization campaigns. A simple economic-growth policy remains a [hypothesis](economic-first-exploration.md), not approval to change accepted Strategy revisions. The [roadmap](roadmap.md) owns outcome gates; simulator qualification is a later optimization concern, never a prerequisite for gameplay implementation.

**Multi-Ship work:** The Fleet must eventually be able to allocate two or more Ships *together* to one outcome (e.g. producer and hauler), while independent Ships keep doing useful work. A team is one selected contribution with shared dependencies, not multiple competing planners.

## What success looks like

- **Makes money with attribution:** Reports realized Net Earnings and costs, not just credit balance, gross trading spread or a model score. Correctly represents unknown costs as unknown.
- **Uses constraints economically:** Compares opportunities against time to reset, fuel, capital, market depth, evidence uncertainty and eventual API admission pressure. Does not acquire unprofitable information forever or buy idle capacity merely to expand the Fleet.
- **Keeps moving:** Acts on profitable partial evidence; declines or waits when justified; does not let one blocked Commitment monopolize independent Ships.
- **Coordinates:** Selects shared work as an atomic Fleet commitment and recovers only affected dependencies.
- **Survives:** Reconciles unknown mutation effects without blind retries; distinguishes application restart from Server Reset; fences stale-generation authority.
- **Plays the full game:** Makes every relevant pinned API capability autonomously reachable with evidence, recovery and useful planning, not merely an endpoint wrapper.
- **Is intelligible:** The accepted game-first journey is **Glance → Ships → Ship + Why → answer-first Grafana → back**, with Plan Health, Earnings, estimated-versus-realized trade outcomes and a truthful next event. This comes from [#757](https://github.com/bturney/spacetraders/issues/757) and [ADR 0017](../adr/0017-nothing-needs-the-operator.md), replacing old #502/#311 intervention-centric screens.
- **Is testable:** New gameplay loops prove end-to-end behavior with deterministic tests and attributable game evidence. Accelerated actual-bot comparisons become useful once the engine has enough behaviors to optimize; simulator ranks remain model-conditional.

## Ultimate competitive destinations

The final destinations are **real-game achievements**, not just an internal measure of economic efficiency:

- **Top 10 by current credits** on the game's `mostCredits` leaderboard.
- **Top 10 by submitted charts** on `mostSubmittedCharts`. The two top-ten achievements may occur in **different Generations**; achieving both in one Generation *at the same time* is an optional stretch goal.
- **Shortest credible mint-to-completion time** for construction of the Headquarters System's initially unfinished Jump Gate, with this Fleet's own contributions authoritatively attributable. Start with a verified completion and improve a comparable personal best; pursue broader speed records only when comparable external evidence exists.

The official leaderboard metric is game state, and the authoritative rank must be observed in the live game's server-status response; local simulator rankings are decision evidence, not leaderboard placements. The gate-time origin and construction proof follow [spec #677](https://github.com/bturney/spacetraders/issues/677). [The roadmap](roadmap.md) keeps the near-term **sequential outcome gates** distinct from these **independently achievable endgame goals**, so future sprints can learn which method works without predetermining the capability order.

## Product boundaries

The application is a one-Operator, one-current-Agent BEAM/Phoenix/PostgreSQL service ([ADR 0015](../adr/0015-single-operator-single-current-agent.md)). The game remains external truth; the bot cannot guarantee a globally optimal, leaderboard-winning or complete-information strategy. Long-lived correctness protects **irreversible decisions, shared resources and generation identity**; speculative flexibility does not justify a second framework.

This contract describes the destination, not a claim that every capability exists. Track delivered and proven behavior in [capabilities.md](capabilities.md); prioritize the next improvement in [roadmap.md](roadmap.md).
