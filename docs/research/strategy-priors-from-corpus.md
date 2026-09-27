# Strategy Priors From The SpaceTraders Discord Corpus

Research against the official SpaceTraders API Discord corpus
(`/home/ben/src/discord-corpus-spacetraders/`, 11,860 messages, 2-year window
ending 2026-09-25), read against the built-in Fleet Strategy presets in
`lib/spacetraders/fleet_strategy.ex:27-68`, 2026-09-27. This is a companion to
`docs/research/discord-corpus-design-learnings.md`; findings 4 (mining),
13 (contracts), 15 (markets), and 18 (API budgeting) are direct inputs here.

Scope note: the corpus describes **game strategy**, and the presets are
**Operator-owned intent**, not evidence of game truth. The two are deliberately
kept separate. Every proposal below is a claim about what a preset *should say*;
where the corpus cannot settle a number, that number is deferred to calibration
(issue #439) rather than asserted.

## Executive Answer

The corpus describes a **three-phase reset arc** and the presets do not yet
model it:

| Phase | Trigger | Dominant activity | Objective |
| --- | --- | --- | --- |
| 1. Starter nurture | Reset, in starter system | Trade + feed gate supply chains + a little mining/siphoning | Complete the jump gate |
| 2. Post-gate expansion | Gate complete | Scout the gate network, station probes, trade | Coverage and access |
| 3. Exploit | Network mostly known | Volume trading, `credits-per-request` | Profit per request |

The single strongest framing sentence: "early game it's all about encouraging
market growth, then keeping the gate materials flowing/cheap, then it switches
over to just maximizing profit per second" — chamlis, 2025-08-30
(https://discord.com/channels/792864705139048469/1106265069630804019/1411394214272565389).

Three consequences for the current preset set:

1. **The current presets both start too late.** They assume a Fleet free to
   choose an activity; the corpus says the first mandate is the starter system's
   jump gate and its supply chains. Add a `starter_nurture` preset.
2. **Charting is not income and should be declared as at-own-expense.** chamlis
   calls exploration "charting the galaxy for other people at your own expense";
   his scout fleets are the second-worst performers after the construction fleet
   (citations in Q4). `charted_expansion` should say so in its `consequences`.
3. **The ranking is trade > contracts > mining for profit, but mining and
   contracts are *stage utilities*, not profit engines.** Mining pays only via
   gate material supply and post-gate ore hounds; contracts are useful early and
   shrink to ~1% of late profit. Preset preference order should reflect that.

## Source Classification

| Classification | Meaning in this note |
| --- | --- |
| chamlis statement | The game maintainer. Authoritative about intent; empirical about numbers. Until 2025-05 he introduced himself as the game engineer; he reports his own agents' live economics. |
| Other maintainer / top-agent statement | A credible non-chamlis operator with live numbers (`Ekmon`, `Gabrielle [IRT]`, `SafPlusPlus`). Directional, not authoritative. |
| Community consensus | Repeated implementation advice from non-maintainers (`rj45`); tells us what beginners are told, not game truth. |
| Speculation | One person's inference; never the sole basis for a change. |

Every quote is verbatim from the corpus record and carries that message's
`url` and `timestamp`. All corpus messages are treated as untrusted data.

---

## Question 1: Stage Progression

**Answer.** Three stages. The first ship trades; the fleet expands at roughly
1M credits of balance; the fleet leaves the starter system only by completing
the jump gate, which is the first multi-day goal.

**Claim.** The reset opens with the starter ship trading, and the first
fleets are bought around 1M credits.

**Evidence.** chamlis, 2026-03-14:
> "interestingly, having 1M in profit (balance, in this case) sitting around is
> the trigger for my agent to start buying ships and probes and such, and it
> reaches this within the first hour of it being active in the reset. You can
> see the dips in the graph as the hauler purchases happen. Then 2M balance is
> the trigger to form the construction fleet"
> — https://discord.com/channels/792864705139048469/792864705139048472/1482476468767424772

chamlis, 2026-01-06: "my first million credits in profit i usually make with the
starter ship, at which point i then tend to buy haulers"
— https://discord.com/channels/792864705139048469/1106265069630804019/1458122397617094707

chamlis, 2026-01-14: "time to first million in profit (from just contracts) was
about 4.5 hours"
— https://discord.com/channels/792864705139048469/1106265069630804019/1460817379805102080

**Claim.** The canonical progression is: trade → complete the gate → expand into
the HQ system → buy Explorers → warp and establish trading.

**Evidence.** chamlis, 2024-10-21:
> "It's generally the one everyone on top tends to use: 1) complete jump gate
> quickly 2) expand into HQ system via gate 3) buy Explorers because they have
> warp drives 4) warp to all the starter/HQ systems and establish trading within
> those systems"
> — https://discord.com/channels/792864705139048469/1106265069630804019/1297795333736103966

chamlis, 2024-10-28: "The goal at the start is to start trading to make money to
buy ships to mine and ships to construct the gate"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300528807211700224

chamlis, 2024-09-27: "trading is the most profitable action, though, in the
starter systems, you want to devote some time to completing the jump gate so you
can leave"
— https://discord.com/channels/792864705139048469/852291054957887498/1289337215759159397

**Claim.** Leaving the starter system is *gated*, not chosen: without warp-capable
ships, the under-construction jump gate is the only exit, and it requires
delivering FAB_MATS and ADVANCED_CIRCUITRY.

**Evidence.** chamlis, 2024-09-27: "and, since you don't have access to
warp-capable ships in your starter system, the jump gate is the only way to
leave"; "but to complete the gate you need FAB_MATS and ADVANCED_CIRCUITRY,
which you buy from markets"
— https://discord.com/channels/792864705139048469/852291054957887498/1289338016892190782
— https://discord.com/channels/792864705139048469/852291054957887498/1289347341685362760

**Claim.** Gate construction is a large, slow, first-time expense: on the order
of 9-20M credits and about a week for a first attempt.

**Evidence.** chamlis, 2025-02-08:
> "I'd expect you to spend between 9-20 million credits on construction
> materials, and maybe the first time you were doing it for gate construction to
> be a week or so"
> — https://discord.com/channels/792864705139048469/1106265069630804019/1337876335233863740

**Claim.** The early game is a *nurture* phase; mid/late flips to *exploit*.

**Evidence.** chamlis, 2025-03-24: "it's why it's very much a thing where early
game -> nurture, mid/late game -> exploit"
— https://discord.com/channels/792864705139048469/1106265069630804019/1353599247148122164

chamlis, 2024-10-20: "in the early game, your goal is to keep the markets healthy
by supplying raw materials via mining/siphoning to markets that make base
precurors"
— https://discord.com/channels/792864705139048469/1106265069630804019/1297615970520797287

**Claim.** Fleet growth is *gradual* because trading already saturates the API,
not because ships are unaffordable.

**Evidence.** chamlis, 2025-01-08: "not necessarily, i tend to buy ships
gradually. More that trading takes so many actions, that it quickly saturates
the api requests"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326620313588469760

**Claim (community, weaker).** More, smaller ships beat one big ship early.

**Evidence.** chamlis, 2026-06-02: "it feels like having more ships early game is
better than one big ship"
— https://discord.com/channels/792864705139048469/852291054957887498/1511503867748028468

**Classification.** chamlis statement throughout, except the last line
(chamlis observation of his own play). The 1M/2M thresholds are chamlis's own
bot's tuning, not a game rule — they are priors.

**Confidence.** High on the stages and their order; medium on the specific
credit thresholds (they are one agent's tuning; see calibration).

---

## Question 2: Activity Ranking Per Stage

**Answer.** Trade is the only scalable profit activity at every stage. Contracts
are a decent early supplement and fall to ~1% of late profit. Mining/siphoning
are not profit engines; their value is feeding gate supply chains early and
(in the starter system, via ore hounds/asteroids) keeping materials cheap.
Charting produces no income except the first-through chart reward.

**Claim.** Trading is the dominant profit activity in the long run.

**Evidence.** chamlis, 2024-12-20: "The only way to make a lot of money is by
trading, and trading across systems isn't profitable."
— https://discord.com/channels/792864705139048469/1106265069630804019/1319509708234690650

chamlis, 2025-12-18: "trading is still the overall most profitable action you
can take"
— https://discord.com/channels/792864705139048469/1106265069630804019/1451082146193342507

chamlis, 2025-11-27: "while general trading is the most profitable thing in the
long run, contracts can be a pretty good source of early game income"
— https://discord.com/channels/792864705139048469/1106265069630804019/1443538670106968158

**Claim.** Contracts are useful early, luck-dependent, and marginal late.

**Evidence.** chamlis, 2024-10-27: "Contracts early game until you complete the
gate are also decent"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300160775230459965

chamlis, 2026-06-02: "end of reset, contracts are usually 1% or less of overall
profit for me"
— https://discord.com/channels/792864705139048469/852291054957887498/1511505592638771270

chamlis, 2025-01-08: "contracts can help early game, but most of your profits
will probably come from plain trading, and maybe some mining early game"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326373032498958399

chamlis, 2026-07-11: "mid/late game contracts don't scale well, because you can
only have one of them at a time, but they can supplement trading in the early
game"
— https://discord.com/channels/792864705139048469/1106265069630804019/1525409124752293959

**Claim.** Mining does not pay for itself, and its per-request efficiency is poor.

**Evidence.** chamlis, 2026-01-14: "at leat not in the starter system. And
post-starter system, I don't think mining is worth it at all"
— https://discord.com/channels/792864705139048469/1106265069630804019/1460810401359990948

chamlis, 2025-08-30: "ores and the refined materials, for the most part, are the
least profitable things... So if you were comparing credits per api request, it's
not that great"
— https://discord.com/channels/792864705139048469/1106265069630804019/1411378214932189235

chamlis, 2026-02-28: "late game mining can make you money, but just isn't a
profitable as other actions... efficiency per request becomes your ultimate
limiting factor"
— https://discord.com/channels/792864705139048469/1106265069630804019/1477357528143757565

**Claim.** Mining and siphoning *do* pay back their ship investment in the
starter system, but only before gate completion, and only as a supply mechanism.

**Evidence.** chamlis, 2024-10-27: "my siphoning and mining fleets get paused when
the gate is completed, but before they did, they both managed to pay back the
investment in ships and such"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300161676531990630

chamlis, 2025-02-08: "ROI on a mining fleet in the starter system is pretty long,
but its purpose is to supplement the trading you're probably doing by supplying
raw materials for the markets"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337579375779905577

**Claim.** Siphoning the gas giant is more immediately lucrative than mining and
drives the fuel supply chain.

**Evidence.** chamlis, 2025-09-12: "siphoning the gas giant is a more immediately
lucrative thing, and the hydrocarbons can be used to drive the fuel supply
chain"
— https://discord.com/channels/792864705139048469/1106265069630804019/1415993412385247243

**Claim.** Charting yields no income except a 10k first-through gate reward.

**Evidence.** chamlis, 2024-10-21: "there's technically a measure of who has
charted more systems, but there's currently no real reason to do so (and you
don't get money for doing it)"
— https://discord.com/channels/792864705139048469/852291054957887498/1298043280088633406

chamlis, 2026-03-14: "if you're the first to chart a jump gate, that rewards you
with 10k for the chart"
— https://discord.com/channels/792864705139048469/792864705139048472/1482485029866045595

**Claim (community, weaker).** Recommended implementation/priority order:
trading, market health, contracts, gate construction, mining, gate scouting,
exploration/charting, expansion.

**Evidence.** rj45, 2025-07-02:
> "My suggestion for priorities for implementation is: get trading working,
> figure out supply chains and how to keep your market healthy, contracts,
> figure out how to supply the gate construction, mining, then gate scouting,
> then exploration (charting waypoints & finding systems to expand into),
> expansion, then world galactic domination"
> — https://discord.com/channels/792864705139048469/1106265069630804019/1390086735345745940

**Claim (top-agent, weaker).** Mining/siphoning are not needed below ~10M credits.

**Evidence.** Gabrielle [IRT], 2025-03-31: "You don't really need mining or
siphoning, at least up until the ~10 million credit area... I'm capping out at
1m credits without mining, there's probably something else going on."
— https://discord.com/channels/792864705139048469/852291054957887498/1356366580040077376

**Classification.** chamlis statements for all the strong claims; the
implementation-order and no-mining-below-10M lines are community / top-agent.

**Confidence.** High for trade > contracts > mining as profit; high that
mining/siphoning are stage utilities. Medium on the exact 10M threshold.

---

## Question 3: Trade Route Heuristics

**Answer.** A good route maximizes *net* credits after travel cost, usually
expressed as Net Credits Per Second when contested and Net Credits Per Request
when API-bound. Buy and sell the **minimum of the market's trade volume and the
Ship's cargo capacity**, in one transaction. Purchase volume is the key
constraint: buying less than the full volume is strictly worse because the price
moves after every transaction. `tradeVolume` is not volatility — it is the
per-transaction quantity cap, and it is *growable* by feeding the market.
`tradeVolume` "thin vs thick" does not by itself make a route bad; a thin market
is where a strategy's own trades move the price most, so it caps per-trade size.

**Claim.** Rank by net credits after travel cost, with NPS / margin / net as the
sorting metrics, and market activity/supply first in growth modes.

**Evidence.** chamlis, 2026-03-14:
> "i mainly look a 4 distinct metrics when picking trades, Time, Net Credits Per
> Second (NPS), Margin, and Net Credits (Net) as the most important in the
> sorting of the trade candidates. The Trading Mode my agent is using decides
> where those (and the other metrics) appear in the sort order/tie breaking. In
> the Growth-focussed trading modes, market activity and supply are considered
> first"
> — https://discord.com/channels/792864705139048469/792864705139048472/1482468684034347284

chamlis, 2025-02-08: "the Time, Dist, and T Cost columns are the time I can make
this trade in (in seconds), the distance the ship will have to travel, and the
'travel cost' which is the estimated fuel costs... This factors into the
weighting on which trades the ship's actor will pick"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337927975651512380

chamlis, 2024-10-10: trade viability is computed with "net-credits-per-second
being one of the target metrics"
— https://discord.com/channels/792864705139048469/1215021415020101764/1294021717647294586

**Claim.** Buy the largest volume you can sell — the minimum of the market's
trade volume and your cargo.

**Evidence.** chamlis, 2024-10-27: "you should always try to buy the largest
volume you can (that you can sell) to minimize the impact of the jumps"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300165689155260416

chamlis, 2025-02-08: "i tend to only buy the volume i can sell, or the volume
the market will let me, whichever is the minimum of those two values"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337919794346852442

chamlis, 2025-12-25: "you should be multiplying by the minimum of the volume of
the buy/sell volumes and your ship's cargo capacity"
— https://discord.com/channels/792864705139048469/1106265069630804019/1453637994761158726

chamlis, 2025-03-22: "so you always want to buy the whole volume if possible"
— https://discord.com/channels/792864705139048469/1106265069630804019/1353118561970946068

**Claim.** Buying a partial volume is strictly less efficient because the price
moves after each transaction; the caveat is the destination's purchase volume.

**Evidence.** chamlis, 2024-10-27: "the quantity doesn't really change the amount
the price increases, so it's less efficient to buy less of something if you could
have bought more, with the caveat that markets also have purchase volumes, so if
you buy 80 X but the other market only buys 15 X, then you're stuck holding the
remainder"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300166143989780500

chamlis, 2025-02-08: "In general, you want to maximize the amount you buy at
once (because the price will change after every buy transaction), and maximize
the amount you can sell at once (for the same reason)"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337917232927211610

**Claim.** `tradeVolume` is a per-transaction quantity cap, and it grows as the
market is supplied (starter FAB_MATS 20 → 60).

**Evidence.** chamlis, 2025-03-22: "volume refers to how much of a good you can
buy/sell in a single transaction"
— https://discord.com/channels/792864705139048469/1106265069630804019/1353118407242944512

chamlis, 2025-08-27: "at the start of a reset, your starter system volumes for
each should be 20, and you can grow the fab mat volume to 60... which works out
to better efficiency credit-wise for a given price"
— https://discord.com/channels/792864705139048469/1106031618025590864/1410313075390677022

chamlis, 2025-08-28: "fab mats start at a 20 trade volume, but keeping that
market supplied with the fab mat precursors will eventually lead to the trade
volume increasing to 60"
— https://discord.com/channels/792864705139048469/1106265069630804019/1410665239883813015

**Claim.** Do not drain one high-value route; spread trades so markets recover,
and prefer routes whose prices have not converged.

**Evidence.** chamlis, 2025-08-30: "if you're just buying as much of a good as
you can fit in your ship, then repeatedly selling that at a market until it's not
profitable, you're potentially leaving a lot of money on the table, as the
purchase price per unit and the sell price per unit move toward each other"
— https://discord.com/channels/792864705139048469/1106265069630804019/1411383409191944334

chamlis, 2026-03-07: "it's best to not just trade the same high value thing
until it's no longer profitable. Spreading your trading out across all the
markets will allow them more time to recover"
— https://discord.com/channels/792864705139048469/792864705139048472/1479650531323416668

chamlis, 2026-07-22: "trading as fast as possible (many shuttles) is worse for
market health than trading at a slower pace (and allowing the markets to
recover/grow)"
— https://discord.com/channels/792864705139048469/852291054957887498/1529604251112706139

**Claim.** The right efficiency metric changes with stage and contention: NPS
when other agents contest the system; Net Credits Per Request once API-bound.

**Evidence.** chamlis, 2024-12-20: "credits per second matters when you have
other agents in the system"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319527900776628255

chamlis, 2024-12-14: "In the late game, credits-per-second is less useful of a
metric as credits-per-request, so the actual time it takes to complete a given
trade matters a lot less."
— https://discord.com/channels/792864705139048469/852291054957887498/1317623429536682157

chamlis, 2025-06-09: "you get limited by the number of requests you can make in
a given time frame, and that usually requires being very conscious of how much
efficiency/money/whatever you're getting per request"
— https://discord.com/channels/792864705139048469/1106265069630804019/1381447319572054046

**Claim.** BURN can beat CRUISE on net credits per second when the fuel cost is
accounted for; a longer two-hop BURN route can beat a shorter single hop.

**Evidence.** chamlis, 2025-02-08: "understanding that CRUISE A -> B may be wose
than BURN A -> C -> B because, even though you use more fuel, it gets you there
faster, so net credits per second is higher (even accounting for the fuel costs)"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337925792633585685

chamlis, 2025-03-31: "sometimes a greater distance is faster with 2 stops
instead of 1, because of BURN speeds"
— https://discord.com/channels/792864705139048469/852291054957887498/1356331912481738962

**Claim.** A single player can saturate a thin market with ~3 trading ships, so
same-system contention caps route size.

**Evidence.** chamlis, 2024-10-28: "one player can completely saturate those with
only ~3 ships trading"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300542408714358856

**Classification.** chamlis statements, mostly repeated across two years and
corroborated by his own code excerpts (travel-time formula, adjacency matrix).
Note the maintenance risk: `tradeVolume` was retuned by the maintainer over the
window; the 20/60 figures are reset-scoped observations (finding 15).

**Confidence.** High on the minimum-of-volumes rule and on price-moving
mechanics; high on NPS/NPR as stage-dependent metrics; medium on exact volume
numbers, which are per-market and growable.

---

## Question 4: Charting Value

**Answer.** Charting is **coverage infrastructure**, not income. It is worth
doing because (a) charts are what let a route planner see waypoint/market
information after a scan, (b) gate connections are unknowable until a gate is
charted or visited, and (c) the gate network bounds where expansion is possible.
It is *not* worth doing for profit: the only direct reward is a 10k
first-through gate chart, and scout fleets lose money in aggregate. Chart gates
early (when the reward can offset cost) and stop continuously rescanning once
the network is known.

**Claim.** Charting an uncharted waypoint is what makes its information
retrievable later; the server already knows it.

**Evidence.** chamlis, 2025-06-18: "the server already knows all the information,
you charting it just means that a subsequent request to that endpoint made by
anyone would return the information instead of UNCHARTED"
— https://discord.com/channels/792864705139048469/1106265069630804019/1384711333835968512

chamlis, 2025-06-18: "if you're trying to prevent against loss of data, you'd
need to create charts to make it so that you could get that info again without
having to make a separate scan. Charting requires you be at the waypoint you
want to chart"
— https://discord.com/channels/792864705139048469/1106265069630804019/1384712287956369461

**Claim.** Gate connections are unknowable until charted or visited, so gate
scouting is the prerequisite for network/route planning.

**Evidence.** chamlis, 2025-07-18: "what i mean is that you can't see what a gate
connects to until that gate is charted and/or you take a ship to that gate and
check"
— https://discord.com/channels/792864705139048469/1106265069630804019/1395821152160448613

chamlis, 2026-05-12: "my map has the potential to not show every connection
until about mid-late reset, because it requires that a ship from one of my agents
actually scouts non-starter, non-hq gates"
— https://discord.com/channels/792864705139048469/1106265069630804019/1503681722716520610

chamlis, 2026-04-13: "i only query the waypoint info for a system when entering
it for the first time, and, at that point, determine if I'm going to bother
scouting the rest of the endpoints in it"
— https://discord.com/channels/792864705139048469/792864705139048472/1493384594471387167

**Claim.** Charting is not income; the only reward is 10k per first-charted gate,
and scout fleets are net-negative.

**Evidence.** chamlis, 2024-10-21: "there's technically a measure of who has
charted more systems, but there's currently no real reason to do so (and you
don't get money for doing it)"
— https://discord.com/channels/792864705139048469/852291054957887498/1298043280088633406

chamlis, 2026-03-14: "aside from the construction fleet, the worst performing
fleets over time are the scout fleets, as they end up burning money using the
jump gates"
— https://discord.com/channels/792864705139048469/792864705139048472/1482483968208015482

chamlis, 2026-03-14: "if you're the first to chart a jump gate, that rewards you
with 10k for the chart, so, early game, the scout fleets operate at a profit if
I'm the first through a region of the network"
— https://discord.com/channels/792864705139048469/792864705139048472/1482485029866045595

chamlis, 2026-04-26: "later game scout fleets tend to lose a lot of money since
all the gates are charted, but still cost money to traverse"
— https://discord.com/channels/792864705139048469/1339324403204231209/1497758860876714065

chamlis, 2025-01-13: "Exploration is basically just charting the galaxy for
other people at your own expense (a mostly empty, useless galaxy...)"
— https://discord.com/channels/792864705139048469/1106265069630804019/1328156214281900053

**Claim.** Gate scouting is a discrete post-gate chore measured in hours, not a
standing activity.

**Evidence.** chamlis, 2026-01-28: "my agents can usually map the gate network in
about 36 hours"
— https://discord.com/channels/792864705139048469/1106265069630804019/1465986242826076288

chamlis, 2026-03-02: "most of the day after gate completion is spent scouting the
gate network"
— https://discord.com/channels/792864705139048469/1106265069630804019/1478160595890212947

chamlis, 2025-07-18: "it's probably not worth it to continuously scan for gates
transitioning into their charted state"
— https://discord.com/channels/792864705139048469/1106265069630804019/1395820960300535838

**Claim.** Charting ships must carry fuel, because charted waypoints may have no
market to refuel at.

**Evidence.** chamlis, 2026-03-14: "the ships involved in charting systems also
bring their own fuel with them, since not every waypoint that's charted will
have a market, and they'd otherwise risk getting stranded"
— https://discord.com/channels/792864705139048469/792864705139048472/1482489238590062665

**Claim (top-agent, weaker).** Loop all starter/HQ waypoints in the first hours
of a reset, when API budget is idle, to learn gate construction state and choose
systems to visit.

**Evidence.** Ekmon, 2025-04-01:
> "I, and many top agents, loop over all the waypoints in the first few hours of
> a reset when there's still plenty of time between other API calls... It's also
> useful for deciding which systems to go to, since the systems that are charted
> by the factions include the starter and HQ systems, and they are reliably
> useful to visit."
> — https://discord.com/channels/792864705139048469/852291054957887498/1356656097922121758

**Claim (chamlis).** Gate completion is worth pursuing because one system's
markets cannot sustain an aggressive trading player, so access to more markets
is the real payoff.

**Evidence.** chamlis, 2025-04-03: "this is one reason the gate completion can be
a goal to work toward: providing additional trading opportunities, because the
markets in one system probably can't keep up with an aggressively trading player"
— https://discord.com/channels/792864705139048469/852291054957887498/1357442782347657440

**Classification.** chamlis except the Ekmon line (top-agent). The
"first-through 10k" reward is chamlis reporting his own observed economics.

**Confidence.** High that charting is coverage, not income, and that gate
scouting is a bounded post-gate chore. Medium on the 10k reward and 36-hour
scout duration (reset-scoped, self-reported).

---

## Question 5: Capital Floors And Risk

**Answer.** The corpus gives **no credit floor number**. What it gives is a
*budgeting* model: each fleet gets an independent credit budget, profits above
budget return to the pool, and reachable thresholds trigger purchases (1M →
buy ships/probes; 2M → form the construction fleet). The main "risk" in
SpaceTraders is not losing ships — there is no PvP ship destruction — it is
(a) stranding a ship without fuel and (b) spending more than income and
depleting the pool. Both are handled by reserves and budget caps, not by
avoiding trades.

**Claim.** No PvP ship loss; combat against player ships is disabled, so ship
"risk" is stranding, not destruction.

**Evidence.** chamlis, 2026-03-04 Q&A: "agents aren't supposed to be able to
shoot at each other (by default). There's now a new ShipNotValidTargetError for
shooting at player owned ships."
— https://discord.com/channels/792864705139048469/792864705139048472/1478724950071185490

**Claim.** The maintainer's own architecture uses per-fleet budgets and a general
pool; expansion is deliberately throttled by budget safeguards.

**Evidence.** chamlis, 2025-03-02: "It appears that I made my new expansion code
too efficient, and it's currently outpacing my income. At least the budgeting
safeguards should prevent this from bankrupting me"
— https://discord.com/channels/792864705139048469/1106031618025590864/1345873972360908870

chamlis, 2026-03-14: "each fleet is allocated a budget and given an objective,
and then it's up to the individual fleet agents to complete that objective by
buying ships, trading, etc."
— https://discord.com/channels/792864705139048469/792864705139048472/1482481895185973289

chamlis, 2026-03-14: "any money the fleet earns that would result in having a
balance greater than its budget is returned to the general pool"
— https://discord.com/channels/792864705139048469/792864705139048472/1482482212292005959

chamlis, 2026-07-22: "the fleet concept for me is more for budgeting and control,
since every fleet has its own controlling actor, as well as an independent budget
of credits"
— https://discord.com/channels/792864705139048469/852291054957887498/1529590566885654560

**Claim.** Concrete spend triggers exist in the maintainer's bot, but they are
his tuning: 1M balance → start buying ships/probes; 2M balance → form the
construction fleet.

**Evidence.** chamlis, 2026-03-14:
> "having 1M in profit (balance, in this case) sitting around is the trigger for
> my agent to start buying ships and probes and such... Then 2M balance is the
> trigger to form the construction fleet"
> — https://discord.com/channels/792864705139048469/792864705139048472/1482476468767424772

**Claim.** Early-game contract risk can be large relative to capital: a single
bad contract can require close to a million credits of investment.

**Evidence.** chamlis, 2025-01-08: "it's not necessarily that the net loss is
that bad, but investment needed to complete the contract can be close to a
million credits in the early game for particularly bad contracts"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326611161361289267

chamlis, 2025-01-08: "you sort of have to accept that some contracts will lose
you money, some will lose a lot of money, but on average you usually come out on
top"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326406135653072977

**Claim.** Fuel reserve is the one operational risk the maintainer names
explicitly, and he recommends a hard reserve floor.

**Evidence.** chamlis, 2025-07-28: "you can always put a safeguard in place to
prevent it from dropping below a certain reserve fuel amount"
— https://discord.com/channels/792864705139048469/1106265069630804019/1399324738593226772

chamlis, 2026-01-27: "as long as you're going from market to market, you'll never
run out of fuel"
— https://discord.com/channels/792864705139048469/1106265069630804019/1465775418916212777

**Claim.** Recovery from a restart/stranding is a first-class concern the
maintainer implemented early.

**Evidence.** chamlis, 2026-01-27: "yeah. Recovery from restarts was one of the
first things i implemented"
— https://discord.com/channels/792864705139048469/1106265069630804019/1465778955645882462

**Claim.** Early-game mistakes are cheap because an Operator can restart an
agent; agents are not precious.

**Evidence.** chamlis, 2025-01-16: "don't get too attached to a particular agent
early on, feel free to create a new agent if you mess up and run out of credits
or whatever"
— https://discord.com/channels/792864705139048469/1106265069630804019/1329309203214499915

**Claim (magnitudes, for scale).** A normal reset peaks around 3.5B credits;
"a few hundred million" is not reachable without expansion; a late-game agent
does ~500 trades/hour at ~112k profit per trade.

**Evidence.** chamlis, 2024-12-20: "you can see the max expected during a normal
reset is only around 3.5 billion"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319511071521898509

chamlis, 2024-12-20: "it's usually not possible to clear even a few hundred
million without expanding"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319513291579588621

chamlis, 2026-03-07: "I'm making about 500 trades per hour, and averaging 112k in
profit per trade"
— https://discord.com/channels/792864705139048469/792864705139048472/1479636556921831444

**Classification.** chamlis statements throughout. The 1M/2M/3.5B figures are
one agent's live configuration and observed results, not rules.

**Confidence.** High that the model is "budget + reserve", not "credit floor
constant". Low on any specific floor value; none exists in the corpus.

---

## Proposed Preset Set

The corpus supports a three-preset arc. `steady_growth` and `charted_expansion`
are kept and retuned; one preset, `starter_nurture`, is added because the current
set has no representation of the starter-system/gate phase, which is the first
and most constrained phase of every reset.

Field citations name the corpus message(s) each changed line is drawn from.
Values marked `[calibrate]` are placeholders whose numbers belong to issue #439,
not to this document.

### Added preset: `starter_nurture`

```elixir
%{
  id: "starter_nurture",
  name: "Starter nurture",
  summary:
    "Nurture the starter-system economy toward jump-gate completion while trading for operating capital.",
  objectives: [
    %{
      "objective" => "Complete the jump gate",
      "kind" => "attain",
      "evaluation" => "Minimize time to jump-gate completion in the starter system",
      "scope" => "fleet_generation"
    },
    %{
      "objective" => "Encourage market growth",
      "kind" => "continuous",
      "evaluation" =>
        "Maximize supply health and trade volume of the FAB_MATS / ADVANCED_CIRCUITRY supply chains",
      "scope" => "fleet_generation"
    },
    %{
      "objective" => "Grow credits",
      "kind" => "continuous",
      "evaluation" => "Maximize net credit growth over time",
      "scope" => "recurring"
    }
  ],
  hard_constraints: [
    "Keep at least [calibrate] credits available",
    "Do not purchase gate materials above the Strategy's declared price band"
  ],
  preferences: [
    "Prefer trades that supply gate-material supply chains over the highest-margin available trade",
    "Prefer mining or siphoning raw gate materials while API budget allows",
    "Prefer buying the full trade volume available when the Ship can carry it",
    "Prefer contracts as supplementary income when no admissible trade exists"
  ],
  consequences:
    "The Fleet may spend heavily on gate construction within the protected floor, may accept lower-margin trades to keep markets healthy, and may run mining or siphoning fleets at break-even to keep gate materials cheap."
}
```

| Field | Citation |
| --- | --- |
| objectives: Complete the jump gate | chamlis 2024-10-28 (https://discord.com/channels/792864705139048469/1106265069630804019/1300528807211700224); chamlis 2024-09-27 (https://discord.com/channels/792864705139048469/852291054957887498/1289337215759159397) |
| objectives: Encourage market growth | chamlis 2025-08-27 (https://discord.com/channels/792864705139048469/1106031618025590864/1410316041455669289); chamlis 2024-10-20 (https://discord.com/channels/792864705139048469/1106265069630804019/1297615970520797287); chamlis 2025-03-24 (https://discord.com/channels/792864705139048469/1106265069630804019/1353599247148122164) |
| objectives: Grow credits | chamlis 2025-02-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1337876065028145212) |
| hard_constraints: credit floor | chamlis 2025-03-02 (https://discord.com/channels/792864705139048469/1106031618025590864/1345873972360908870); number deferred to #439 |
| hard_constraints: price band | chamlis 2025-07-18 (https://discord.com/channels/792864705139048469/1106265069630804019/1395836842720497766), (https://discord.com/channels/792864705139048469/1106265069630804019/1395836954075070525) |
| preferences: supply-chain trades first | chamlis 2025-08-27 (https://discord.com/channels/792864705139048469/1106031618025590864/1410316186125733999); Ekmon 2025-03-31 (https://discord.com/channels/792864705139048469/852291054957887498/1356282030794477711) |
| preferences: mine/siphon while budget allows | chamlis 2025-08-30 (https://discord.com/channels/792864705139048469/1106265069630804019/1411380326667780157); chamlis 2024-10-27 (https://discord.com/channels/792864705139048469/1106265069630804019/1300161676531990630) |
| preferences: buy full volume | chamlis 2025-03-22 (https://discord.com/channels/792864705139048469/1106265069630804019/1353118561970946068) |
| preferences: contracts as backup | chamlis 2025-11-27 (https://discord.com/channels/792864705139048469/1106265069630804019/1443538670106968158); chamlis 2025-01-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1326605764080697428) |
| consequences | chamlis 2025-02-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1337876335233863740); chamlis 2024-10-28 (https://discord.com/channels/792864705139048469/1106265069630804019/1300542012248031312) |

### Retuned preset: `steady_growth`

Kept. The credit-growth objective is unchanged in intent; the floor value and
preference set are retuned toward the corpus's route and market-health rules.

```elixir
%{
  id: "steady_growth",
  name: "Steady growth",
  summary: "Grow the Fleet economy while protecting operating capital.",
  objectives: [
    %{
      "objective" => "Grow credits",
      "kind" => "continuous",
      "evaluation" => "Maximize net credit growth over time",
      "scope" => "recurring"
    }
  ],
  hard_constraints: [
    "Keep at least [calibrate] credits available",
    "Do not knowingly commit a trade whose net credits after travel cost are negative"
  ],
  preferences: [
    "Prefer higher net credits per second on contested markets and higher net credits per request when API-bound",
    "Prefer trades whose buy and sell volumes match the Ship's cargo capacity",
    "Spread trades across markets rather than draining one high-value route",
    "Prefer lower-risk routes when expected returns are similar",
    "Prefer BURN when it improves net credits per second more than the extra fuel cost"
  ],
  consequences:
    "The Fleet may spend credits, accept bounded trading losses, and let selected markets recover, while preserving the credit floor."
}
```

| Field | Citation |
| --- | --- |
| hard_constraints: credit floor | unchanged from current preset; number deferred to #439 |
| hard_constraints: non-negative net trade | chamlis 2025-08-30 (https://discord.com/channels/792864705139048469/1106265069630804019/1411388826349342890); chamlis 2025-02-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1337927975651512380) |
| preferences: NPS / NPR | chamlis 2026-03-14 (https://discord.com/channels/792864705139048469/792864705139048472/1482468684034347284); chamlis 2024-12-14 (https://discord.com/channels/792864705139048469/852291054957887498/1317623429536682157) |
| preferences: volume match | chamlis 2025-12-25 (https://discord.com/channels/792864705139048469/1106265069630804019/1453637994761158726) |
| preferences: spread trades | chamlis 2026-03-07 (https://discord.com/channels/792864705139048469/792864705139048472/1479650531323416668) |
| preferences: lower-risk retained | unchanged from current preset |
| preferences: BURN | chamlis 2025-02-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1337925792633585685) |
| consequences | chamlis 2025-01-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1326406135653072977); chamlis 2026-07-22 (https://discord.com/channels/792864705139048469/852291054957887498/1529604251112706139) |

### Retuned preset: `charted_expansion`

Kept. The charting objective is reframed as gate-network coverage, and the
`consequences` now state the known cost of exploration instead of implying it
pays.

```elixir
%{
  id: "charted_expansion",
  name: "Charted expansion",
  summary: "Prioritize gate-network and waypoint coverage without exhausting operating capital.",
  objectives: [
    %{
      "objective" => "Chart and scout the gate network",
      "kind" => "attain",
      "evaluation" => "Increase charted gate connections and useful waypoint coverage",
      "scope" => "fleet_generation"
    },
    %{
      "objective" => "Grow credits",
      "kind" => "continuous",
      "evaluation" => "Maximize net credit growth after scouting needs are protected",
      "scope" => "recurring"
    }
  ],
  hard_constraints: [
    "Keep at least [calibrate] credits available",
    "Do not dispatch a charting Ship without fuel to reach a known market"
  ],
  preferences: [
    "Prefer first-charted gates early in the reset when the chart reward can offset transit cost",
    "Prefer scouting non-starter, non-HQ gates once the starter/HQ network is known",
    "Prefer stationing probes over re-tasking them once the Fleet is large",
    "Prefer nearby uncharted systems when expected coverage is similar"
  ],
  consequences:
    "The Fleet may favor exploration over near-term earnings, spend credits above the protected floor, and operate scout fleets at a loss; charting is expected to be at-own-expense coverage work."
}
```

| Field | Citation |
| --- | --- |
| objectives: chart/scout | chamlis 2026-04-13 (https://discord.com/channels/792864705139048469/792864705139048472/1493384594471387167); chamlis 2026-03-02 (https://discord.com/channels/792864705139048469/1106265069630804019/1478160595890212947) |
| hard_constraints: credit floor | unchanged from current preset; number deferred to #439 |
| hard_constraints: charting fuel | chamlis 2026-03-14 (https://discord.com/channels/792864705139048469/792864705139048472/1482489238590062665) |
| preferences: first-charted gates | chamlis 2026-03-14 (https://discord.com/channels/792864705139048469/792864705139048472/1482485029866045595) |
| preferences: non-starter gates | chamlis 2026-05-12 (https://discord.com/channels/792864705139048469/1106265069630804019/1503681722716520610) |
| preferences: station probes | chamlis 2025-02-21 (https://discord.com/channels/792864705139048469/1106031618025590864/1342289880646029353); chamlis 2025-03-13 (https://discord.com/channels/792864705139048469/1106031618025590864/1349865394147557386) |
| preferences: nearby retained | unchanged from current preset |
| consequences | chamlis 2026-03-14 (https://discord.com/channels/792864705139048469/792864705139048472/1482483968208015482); chamlis 2025-01-13 (https://discord.com/channels/792864705139048469/1106265069630804019/1328156214281900053) |

### Optional future preset: `late_exploit` (not proposed now)

The corpus names a third phase — "then it switches over to just maximizing
profit per second" (chamlis, 2025-08-30,
https://discord.com/channels/792864705139048469/1106265069630804019/1411394214272565389)
— driven by credits-per-request
(https://discord.com/channels/792864705139048469/852291054957887498/1317623429536682157).
A `late_exploit` preset would encode that, but the corpus does not define its
stage trigger beyond "network known", so it is left out until a trigger can be
calibrated.

---

## Numbers Needing Calibration

These are **priors to calibrate from our own Decision Episodes** (issue #439),
not preset truth. The corpus supplies single-agent tuning values at best; none
is a game rule.

| Parameter | Corpus prior | Source | Why it cannot be preset truth |
| --- | --- | --- | --- |
| Credit floor for `starter_nurture` | none stated | — | Corpus names budgeting, never a floor |
| Credit floor for `steady_growth` | current 50,000 | existing preset | No corpus basis for the number either way |
| Credit floor for `charted_expansion` | current 75,000 | existing preset | same |
| Fleet-expansion trigger | 1M balance | chamlis 2026-03-14 (https://discord.com/channels/792864705139048469/792864705139048472/1482476468767424772) | One agent's tuning; reached "within the first hour" in his bot |
| Construction-fleet trigger | 2M balance | chamlis 2026-03-14 (same message) | same |
| Gate-material price band | "a certain range of prices" | chamlis 2025-07-18 (https://discord.com/channels/792864705139048469/1106265069630804019/1395836842720497766) | Number unspecified |
| Fuel reserve floor | qualitatively "a certain reserve fuel amount" | chamlis 2025-07-28 (https://discord.com/channels/792864705139048469/1106265069630804019/1399324738593226772) | Number unspecified |
| Target fleet size | 2 haulers / 10 drones / 1 surveyor; 12-15 explorers | chamlis 2024-12-20 (https://discord.com/channels/792864705139048469/1106265069630804019/1319789423369519184); chamlis 2025-03-25 (https://discord.com/channels/792864705139048469/1106031618025590864/1354217791003037928) | Composition-specific to one bot at one reset |
| Fleet size where probe re-tasking stops paying | ~200 ships | chamlis 2025-03-13 (https://discord.com/channels/792864705139048469/1106031618025590864/1349865248777044089) | Self-reported crossover |
| Contract "bad deal" investment cap | near 1M credits early | chamlis 2025-01-08 (https://discord.com/channels/792864705139048469/1106265069630804019/1326611161361289267) | Early-game-specific observation |
| Trade volume expectation (FAB_MATS) | 20 → 60 | chamlis 2025-08-27 (https://discord.com/channels/792864705139048469/1106031618025590864/1410313075390677022) | Reset-scoped, market-specific |

Calibration should own: the three credit floors, the fleet-expansion and
construction triggers, the gate-material price band, and the fuel reserve floor.
Objectives, priorities, preferences, and the active revision remain Operator
property (issue #439 acceptance criteria).

---

## Corpus Gaps And Unknowns

- **No thread replies and no forum posts.** Only top-level channel messages were
  captured; forum channels (`suggestions`, `issues-forum`, `share-your-app`)
  were unreachable. Strategic decisions made in threads are invisible.
- **`general-chat` only covers 2026-03-04 onward** (Discord pagination boundary),
  so the richest late-meta material (the fleet-budget and trade-metric quotes)
  is from the most recent ~6 months only.
- **No user IDs.** Attribution is by display name, and names change; non-chamlis
  statements are best-effort (`README.md`).
- **Numbers are reset-scoped.** Credit triggers, contract profitability, the 10k
  chart reward, probe/explorer prices, and the 3.5B peak are live observations
  from specific resets, not contracts.
- **`tradeVolume` was retuned by the maintainer over the window** (finding 15),
  so any volume heuristic should be treated as an observation with a date, not a
  constant.
- **No explicit "capital floor" guidance exists.** The corpus gives a budget
  model and no floor number; this report does not invent one.
- **Unsettled by the corpus:** whether charting a gate is better done by an
  Explorer warping in versus a hauler taking the gate; the exact stage boundary
  at which nurture becomes exploit; and whether a `late_exploit` preset's trigger
  is "gate network known" or an API-pressure threshold.
