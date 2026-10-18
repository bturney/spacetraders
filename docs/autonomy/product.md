# Product contract: an economically intelligent Fleet worth watching

## North star

SpaceTraders is primarily an economics and resource-allocation game. Build a Fleet that plays autonomously from mint through Server Reset, turns scarce credits, Ship time, Cargo, information and API capacity into **useful outcomes**, and exposes enough causal and economic evidence that an Operator can enjoy watching it and compare different approaches.

**Autonomy:** The machine selects Ships, methods and timing. The single Operator is not asked to play manually or rescue routine stalls. The product can report that it is stuck or off plan without turning that into a request for human gameplay. See [ADR 0017](../adr/0017-nothing-needs-the-operator.md). Stopping the service is the accepted kill switch.

**Economic-first direction:** A simple built-in economic-growth policy is the leading hypothesis for an enjoyable default; future variations (gate-first, charting, exploration or different risk appetites) should earn their way in through experiments. This is **not yet approval** to remove durable Strategy revisions or the currently accepted objective model. See [economic-first exploration](economic-first-exploration.md).

**Multi-Ship work:** The Fleet must eventually be able to allocate two or more Ships *together* to one outcome (e.g. producer and hauler), while independent Ships keep doing useful work. A team is one selected contribution with shared dependencies, not multiple competing planners.

## What success looks like

- **Makes money with attribution:** Reports realized Net Earnings and costs, not just credit balance, gross trading spread or a model score. Correctly represents unknown costs as unknown.
- **Uses constraints economically:** Compares opportunities against time to reset, fuel, capital, market depth, evidence uncertainty and eventual API admission pressure. Does not acquire unprofitable information forever or buy idle capacity merely to expand the Fleet.
- **Keeps moving:** Acts on profitable partial evidence; declines or waits when justified; does not let one blocked Commitment monopolize independent Ships.
- **Coordinates:** Selects shared work as an atomic Fleet commitment and recovers only affected dependencies.
- **Survives:** Reconciles unknown mutation effects without blind retries; distinguishes application restart from Server Reset; fences stale-generation authority.
- **Plays the full game:** Makes every relevant pinned API capability autonomously reachable with evidence, recovery and useful planning, not merely an endpoint wrapper.
- **Is intelligible:** The accepted game-first journey is **Glance → Ships → Ship + Why → answer-first Grafana → back**, with Plan Health, Earnings, estimated-versus-realized trade outcomes and a truthful next event. This comes from [#757](https://github.com/bturney/spacetraders/issues/757) and [ADR 0017](../adr/0017-nothing-needs-the-operator.md), replacing old #502/#311 intervention-centric screens.
- **Is testable:** Controlled real-bot experiments can compare policies/code on pinned worlds with explicit limitations. A simulator rank is a conditional result until mechanics and economic fidelity warrant broader claims.

## Product boundaries

The application is a one-Operator, one-current-Agent BEAM/Phoenix/PostgreSQL service ([ADR 0015](../adr/0015-single-operator-single-current-agent.md)). The game remains external truth; the bot cannot guarantee a globally optimal, leaderboard-winning or complete-information strategy. Long-lived correctness protects **irreversible decisions, shared resources and generation identity**; speculative flexibility does not justify a second framework.

This contract describes the destination, not a claim that every capability exists. Track delivered and proven behavior in [capabilities.md](capabilities.md); prioritize the next improvement in [roadmap.md](roadmap.md).
