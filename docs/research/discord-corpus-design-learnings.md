# Discord Corpus Design Learnings

Research against the official SpaceTraders API Discord corpus
(`/home/ben/src/discord-corpus-spacetraders/`, 11,860 messages, 2-year window
ending 2026-09-25), read against this repo's current design, 2026-09-26.

## Executive Answer

The corpus mostly **confirms** the direction of the current design, and it
**contradicts it in exactly two places that matter**: the API rate-limit budget
and the profitability of mining.

Confirmations worth having in writing: game truth is API-authoritative and
client state is a cache; every player-controlled state change is initiated by
the client (there is no push channel for it), so polling plus aggressive local
caching is the intended shape; one shared, fair, rate-limited client in front of
all workers is how the maintainer's own bot is built; a Server Reset wipes all
generation state on a weekly cadence. Our ADRs 0007, 0010, the Evidence/API
Capacity boundary, `RateLimiter`, and `CapacityGovernor` all read as
downstream of the same design the maintainer describes.

Contradictions to act on:

1. Our token bucket is `rate: 3.0, burst: 10`. The game grants **2 requests per
   second plus a separate 30-request pool per minute** (≈2.5/s theoretical,
   ~2.3/s real). Our sustained rate is over budget by 50%.
2. Mining is presented in `CONTEXT.md` as the first concrete Job. The maintainer
   says mining does not pay for itself, starter-system mining is "pretty meh",
   and post-starter mining is "not worth it at all".

The single most valuable framing sentence in the corpus: "the rate limit is
intended to encourage players to track information, which, honestly, is most of
the game" — which is a direct endorsement of the Observation Demand / Operational
Intelligence model.

## Source Classification

| Classification | Meaning in this note |
| --- | --- |
| chamlis statement | The game maintainer. Highest signal for design intent and live mechanics. Treat as authoritative about intent, empirical about numbers. |
| Other maintainer statement | A person with live-game or upstream knowledge (e.g. `SafPlusPlus`, `Leaf`, `Mr. Hemlock`). Credible but not the game author. |
| Community consensus / folklore | Repeated by multiple non-maintainers; useful for what beginners believe, not for game truth. |
| Speculation | One person's inference; flagged as such and never used as the sole basis for a change. |

Every quote below is verbatim from the corpus record and carries the Discord
`url` for that message. Dates are the corpus `timestamp`.

## Findings

Ranked by impact: what should change in the app, or what assumption it settles.

---

### 1. The game's rate limit is 2/s plus a separate 30/minute pool — our limiter is over budget

**Claim.** The authoritative budget is 2 requests per second sustained plus an
additional pool of 30 requests per minute, not a flat 3/s.

**Evidence.** chamlis, 2025-09-03:
> "you have 2 requests per second, but a separate pool of 30 requests that
> resets every minute that you could burst through in a shorter period of time"
> — https://discord.com/channels/792864705139048469/1106265069630804019/1412892122138284194

chamlis, 2026-02-18: "it's two requests per second plus up to an additional 30
requests every minute"
— https://discord.com/channels/792864705139048469/1106265069630804019/1473736627720421378

chamlis, 2025-12-20: "because of the burst limit, it averages out to around 2.5,
but, realistically … closer to 2.3"
— https://discord.com/channels/792864705139048469/1106265069630804019/1452080990334750822

Classification: chamlis statement, repeated across a year; direct and numeric.

**Our design.** `SpaceTraders.API.RateLimiter` implements a token bucket whose
size is intentionally **"3 req/s sustained, burst 10"** by config
(`config/config.exs:142-144`; `lib/spacetraders/api/rate_limiter.ex:6`). The
capacity governor adds a separate in-flight cap of 10
(`lib/spacetraders/api/capacity_governor.ex:55`). Req also retries 429s with
`Retry-After` (`lib/spacetraders/api.ex:22-23`, `:959-989`).

**Gap / contradiction.** `rate: 3.0` is 50% above the game's sustained grant.
Under sustained load the limiter will emit 429s that Req then absorbs, wasting
the burst pool and risking the throttling chamlis warns about (finding 10). This
is the highest-confidence, cheapest-to-fix finding in the report.

Recommended action: set sustained rate to `2.0` and model the extra pool as a
per-minute `30` grant (or keep a token bucket sized to ≈2.3-2.5/s and document
why). Add a test asserting the configured sustained rate never exceeds 2/s.

**Impact: High.**

---

### 2. One contract at a time per agent

**Claim.** The game allows an Agent to hold at most one active Contract; offers
must be negotiated instead of stacked.

**Evidence.** chamlis, 2025-01-08: "yes, currently one contract at a time per
agent"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326372701190754486

chamlis, 2024-10-28: "contracts are relatively inconsistent as the game goes on,
as you can only have one of them at a time"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300549101905117294

Classification: chamlis statement, direct.

**Our design.** `FleetContracts.reconcile_contract_work/9` behaviorally enforces
this: it fulfils or delivers any `accepted` contract before it will
`accept_if_admissible` an offer (`lib/spacetraders/fleet_contracts.ex:202-247`).
`Contracts.negotiable?/1` requires every listed Contract to be historical before
negotiating (`lib/spacetraders/contracts.ex:61`).

**Agreement, with an undocumented dependency.** The behavior is correct but it
rests on an implicit assumption; nothing local rejects a second acceptance if a
future code path calls `accept_if_admissible/4` while one is active, and the rule
is absent from `CONTEXT.md`.

Recommended action: record "at most one active Contract per Agent" in
`CONTEXT.md` under `Contract`, and add a local guard in `accept_if_admissible/4`
that returns a typed blocker rather than relying on the game's rejection.

**Impact: High** (assumption settled; protects a load-bearing invariant).

---

### 3. Fuel cost equals distance; BURN doubles it

**Claim.** Navigation fuel is the Euclidean distance between Waypoints for
CRUISE, doubled for BURN, so a client can plan range from coordinates.

**Evidence.** chamlis, 2025-05-06: "fuel usage at CRUISE is equal to the
distance. Different modes use different amounts of fuel
https://github.com/SpaceTradersAPI/api-docs/wiki/Travel-Fuel-and-Time"
— https://discord.com/channels/792864705139048469/1106265069630804019/1369460865870598176

chamlis, 2025-05-02: "if you switch your flight mode to BURN … you'll use 2x the
fuel (but also get to the destination quicker)"
— https://discord.com/channels/792864705139048469/1106265069630804019/1367741419258642543

chamlis, 2026-02-28: "fuel is generally equal to distance, double for BURN"
— https://discord.com/channels/792864705139048469/1106265069630804019/1477308499016028251

Classification: chamlis statement; corroborated by the maintainer-linked wiki.

**Our design.** This is already the subject of
`docs/research/refueling-stop-navigation.md:57-78`, which measured the same
rule empirically and declined to treat it as contract truth. The Navigate Intent
sets flight mode but does not derive a fuel budget
(`lib/spacetraders/fleet/intents.ex:4211-4227`); warp is explicitly blocked when
the fuel arithmetic is unknown (`:4463-4465`).

**Agreement and confirmation.** The research note's conservative stance was
right, and the corpus upgrades the rule from "empirical estimate" to a
maintainer-stated intended mechanic. It can now be used to rank or reject legs
(never to override a `navigate` response), and BURN's 2x multiplier is settled
enough to be a checked constant rather than a guess.

Recommended action: cite this corpus message in the navigation research, and
model the per-mode multiplier (at least CRUISE=1.0, BURN=2.0) in the route
policy so BURN planning is not left as "unknown".

**Impact: High.**

---

### 4. Mining does not pay for itself, and asteroids become unstable under load

**Claim.** Mining is a marginal starter-system activity, not a core profit
engine; an asteroid tolerates roughly 8 drones extracting every ~70 seconds
before becoming unstable.

**Evidence.** chamlis, 2024-09-27: "asteroids will become unstable if you mine
too frequently, so the limit is about 8 drones"
— https://discord.com/channels/792864705139048469/852291054957887498/1289337278392565762

chamlis, 2024-09-27: "it's the number of extractions, and extractions can be
made about every 70 seconds for any given mining drone, so 8 of those making
extractions about every 70 seconds is what an asteroid can tolerate"
— https://discord.com/channels/792864705139048469/852291054957887498/1289346885156601906

chamlis, 2026-01-14: "at leat not in the starter system. And post-starter
system, I don't think mining is worth it at all"
— https://discord.com/channels/792864705139048469/1106265069630804019/1460810401359990948

chamlis, 2026-09-04: "my mining fleet never pays for itself before it's
disbanded"
— https://discord.com/channels/792864705139048469/792864705139048472/1545548896988569690

Classification: chamlis statement, repeated over two years including about his
own bot's economics.

**Our design.** `CONTEXT.md` frames the **Miner Job** as "the first concrete
Job" (`CONTEXT.md:259-261`) and the **Survey Job** as a recurring contributor
(`:263-265`). `lib/spacetraders/fleet/intents.ex:1963-2007` already implements
survey-first extraction, and `lib/spacetraders/intelligence/survey.ex` persists
Survey Deposits. There is no modelled asteroid-depletion or per-asteroid drone
limit.

**Contradiction of framing.** The mechanics are implemented well, but the
strategic premise is weaker than the docs imply. Mining's real value per chamlis
is (a) keeping Construction/gate materials cheap and (b) early-game income; it
is not a scalable profit objective. The absence of an unstable/depleted-asteroid
signal means a Miner Job can repeatedly hammer a Waypoint the game is about to
punish.

Recommended action: demote Miner/Survey Jobs in any default strategy ordering,
document the "mining is for gate materials and early game, not profit" framing
in `CONTEXT.md`, and raise an explicit Job Blocker when extraction returns an
invalid/depleted asteroid rather than retrying.

**Impact: High** (challenges a stated product priority).

---

### 5. Server Resets are weekly and regenerate the whole galaxy

**Claim.** A Server Reset replaces world state on a roughly weekly cadence,
including a fully regenerated galaxy; only systems' names may repeat.

**Evidence.** chamlis, 2025-06-08: "every week the server gets reset and the
galaxy gets regenerated. Next reset is in about 10 hours"
— https://discord.com/channels/792864705139048469/1106265069630804019/1381110721433178143

chamlis, 2026-04-13: "resets still happen every week and there are a handful of
active players"
— https://discord.com/channels/792864705139048469/792864705139048472/1493178646020755516

chamlis, 2025-05-28: "the whole galaxy is randomly generated on resets. There
may be some systems with the same names reset to reset, but that's all they'll
have in common"
— https://discord.com/channels/792864705139048469/1106265069630804019/1377135108817158205

Classification: chamlis statement, multiple dates.

**Our design.** ADR 0010 already owns this: Fleet Generation owns Server Reset
transitions, and "Credits, Ships, Contracts, Operational Intelligence, active
work, and all other game-generation state do not [survive]"
(`docs/adr/0010-autonomous-runtime.md:69-74`). Detection is by reset-date
mismatch in `lib/spacetraders/fleet_generation.ex:435-465` and
`:762-788`.

**Agreement, with one operational gap.** The lifecycle is correct, but the
weekly cadence makes persistent Operational Intelligence (markets, shipyards,
waypoints, charts) systematically stale. The design retires generation state;
it does not clearly expire Intelligence that was valid last week.

Recommended action: bind all Operational Intelligence to a Generation and treat
cross-reset reuse as invalid by construction; add a style/test assertion that
post-reset planning starts from empty market/chart intelligence.

**Impact: High** (cadence assumption settled; prevents stale-intelligence bugs).

---

### 6. Only client-initiated state changes; there is no push channel for your ships

**Claim.** Player-controlled state (ships, cargo, contracts, credits) changes
only in response to a client action; only shared world state (charts,
construction, market prices) can change behind your back. Do not expect events
to push ship changes.

**Evidence.** chamlis, 2025-12-18:
> "There's sort of an unspoken contract of 'things you need to handle changing
> without your knowledge, and things you don't.' Right now, all of your ship
> state doesn't change unless you take an action to change it. The status of
> certain waypoints (charting, construction) and market prices can change
> without your knowledge if other players interact with them"
> — https://discord.com/channels/792864705139048469/1106031618025590864/1451259253858766990

chamlis, 2025-12-18: "by keeping it client-side, all state-changes for user
controlled assets are always initiated by the client, and the responses to those
changes contain the new state. This avoids users needing to implement periodic
fetching logic, or everyone needing an exposed endpoint for webhooks"
— https://discord.com/channels/792864705139048469/1106031618025590864/1451251204079484949

chamlis, 2025-12-18: "most of the late game is managing a limited number of api
requests, which is one reason it's good/necessary that all actions are initiated
from the client"
— https://discord.com/channels/792864705139048469/1106031618025590864/1451230173868458166

Classification: chamlis statement; described as an explicit design principle.

**Our design.** `CONTEXT.md` already distinguishes **Shared World State**
(`CONTEXT.md:153-155`) and models evidence as point-in-time observations; ADR
0010 makes every read satisfy a typed Observation Demand
(`docs/adr/0010-autonomous-runtime.md:40-46, :56-61`); reads are polled, not
subscribed.

**Agreement, strongly.** This is the corpus validating the event-free polling
architecture. It also bounds it: because ship state is action-driven, the app
should not poll `get-my-ship` for changes it did not cause — the only
legitimate reasons to re-read are reconciliation of its own ambiguous mutations
and genuine Shared World State. The corpus also notes a websocket/SSE channel
exists but the maintainer ignores its events (2024-10-28:
`https://discord.com/channels/792864705139048469/1106265069630804019/1300499940509880362`).

Recommended action: record "no ship-state push; treat ship reads as
reconciliation-only" as an explicit assumption behind the Observation Demand
design, so no future feature adds speculative ship polling.

**Impact: Medium-high** (architecture validation).

---

### 7. One shared, fair, rate-limited client in front of all workers

**Claim.** The maintainer's own bot funnels every request through a single
client with a governing rate limiter and fairness, so actors never think about
the limit.

**Evidence.** chamlis, 2024-12-20: "people do their rate limiting differently. I
share a single api client instance across all async workers, and that client has
a built in governing rate limiter on it, and a 'fair' interrupt system"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319517803870421054

chamlis, 2025-02-06: "it's actors all the way down … They all have a reference to
an Arc<Client> that itself is rate limited, so the actors just make requests
without really having to consider the rate limit"
— https://discord.com/channels/792864705139048469/1106265069630804019/1337137165498323125

chamlis, 2026-04-25 (his own redesign):
> "My current thought is to have a request arbiter for rate limiting, queuing,
> fairness, and async client sharing. Each galaxy, system, and per-ship
> coordinator would have a tx mpsc channel to a singleton arbiter"
> — https://discord.com/channels/792864705139048469/1339324403204231209/1497749506903638027

Classification: chamlis statement, three independent dates.

**Our design.** `RateLimiter` is a singleton token bucket (`lib/spacetraders/api/rate_limiter.ex:1-16`);
`CapacityGovernor` is the singleton admission gate that orders safety,
reconciliation, then ordinary demand and reports backpressure
(`lib/spacetraders/api/capacity_governor.ex:1-15`). ADR 0010's Evidence/API
Capacity boundary is "the sole route to SpaceTraders reads and mutations"
(`docs/adr/0010-autonomous-runtime.md:40-46`).

**Agreement.** Our two-tier structure (protocol limiter + application admission)
is a superset of the maintainer's one-tier design; the corpus suggests the shape
is right. The only caution is finding 1: the singleton budget constant is wrong.
Note chamlis is undecided on explicit priority levels in his redesign — our lane
ordering is a judgement call he has not validated.

**Impact: Medium-high** (validates a load-bearing architectural choice).

---

### 8. Rate limits are per Agent *and* per IP; do not run agents from one host

**Claim.** The limit applies both per agent token and per source IP, so several
agents on one deployment divide one IP budget.

**Evidence.** chamlis, 2024-12-20: "you should not run multiple agents from the
same machine/ip"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319520520722579516

chamlis, 2026-09-11: "it's per agent and/or per IP"
— https://discord.com/channels/792864705139048469/792864705139048472/1548076346448805944

chamlis, 2026-09-19: "so, in other words, you're dividing a single IP rate limit
between all of them"
— https://discord.com/channels/792864705139048469/792864705139048472/1550968171953918006

Classification: chamlis statement.

**Our design.** ADR 0006 deliberately supports **multiple operators on one
deployment, each minting and playing their own agents** (`docs/adr/0006-game-secrets-in-db-not-env.md:3`),
and `CONTEXT.md` allows an Operator to mint one or more Agents (`CONTEXT.md:21-23`).
`RateLimiter` is a single global singleton regardless of agent
(`lib/spacetraders/api/rate_limiter.ex:1-16`).

**Tension / gap.** Our per-agent tokens are fine, but a multi-agent deployment
shares one egress IP and therefore one IP budget. Our current global limiter
would let two agents each think they own 2/s. This is a documented corpus
boundary, not a bug today (one agent per Operator by default), but it will
surface as soon as a second Agent is minted on the same host.

Recommended action: scope the rate limiter by egress identity (or by
deployment) rather than by Agent, and document the shared-IP budget as a Hard
Constraint on multi-Agent deployment.

**Impact: Medium-high.**

---

### 9. Cache everything; data that doesn't change should never be re-fetched

**Claim.** The intended solution to the rate limit is aggressive local caching of
near-static data and interval-based refresh only for markets, with refresh
tolerance that scales with fleet size.

**Evidence.** chamlis, 2024-12-07: "you should, in general, be caching as much
as you can, as most data doesn't change. Then it's a matter of budgeting your
limited requests to update things like markets"
— https://discord.com/channels/792864705139048469/1106265069630804019/1314937450094919700

chamlis, 2025-11-28: "systems never change, waypoints only sometimes (rarely)
change, etc. Most people cache that kind of information in some way as to not
have to request it again"
— https://discord.com/channels/792864705139048469/1106265069630804019/1444070147361996913

chamlis, 2026-01-20: "my agent starts a reset by walking all the systems and
saving the system and waypoint information in its db"
— https://discord.com/channels/792864705139048469/1106265069630804019/1463303831541514333

chamlis, 2024-12-20: "the cache tolerance for stale market data also increases,
to where i'm about 30 minutes out of date by the end of a reset"
— https://discord.com/channels/792864705139048469/1106265069630804019/1319518538670673982

Classification: chamlis statement, repeated across two years.

**Our design.** `SpaceTraders.Intelligence` records provenance-bearing
observations of waypoints, markets, shipyards, construction, and gates
(`lib/spacetraders/intelligence.ex:110-160`), supports staleness and
invalidation (`:238-283`), and `Opacity`-style demands are governed by the
Capacity Governor.

**Agreement.** The model matches chamlis's mental model. The open question is
whether our freshness policy is as *lazy* as intended: he treats market data at
30 minutes stale as acceptable late-reset, while an aggressive per-Job freshness
requirement would burn the budget he is trying to protect. Our
`fresh_acceptance_evidence/1` already uses a 5-minute window for one decision
(`lib/spacetraders/fleet_contracts.ex:107-113`), which is a reasonable template.

Recommended action: state a per-subject freshness budget (waypoints/systems
essentially never; markets minutes-to-tens-of-minutes; ships only on
reconciliation) and make it configurable, rather than leaving freshness to
individual call sites.

**Impact: Medium-high.**

---

### 10. Avoid hammering the API on repeated 429s; you get throttled

**Claim.** 429s are expected and retryable, but persistently triggering them
triggers throttling, so the client should prevent limits rather than absorb them.

**Evidence.** chamlis, 2024-10-03: "you do want to avoid hitting too many rate
limited responses, though, because you'll get throttled at some point"
— https://discord.com/channels/792864705139048469/1106265069630804019/1291511832619646976

chamlis, 2025-05-17: "If you do get rate limited, you'll get a 429 status code
back, and you can write something to handle that situation (waiting a little
while then re-trying the request, etc.)"
— https://discord.com/channels/792864705139048469/1106265069630804019/1373126068092928010

Classification: chamlis statement.

**Our design.** `lib/spacetraders/api.ex:22-23` documents Req's `Retry-After`
backoff as a safety net; `:959-989` retries 429 for any method because a 429
proves the mutation never applied, and other statuses have method-specific
retry rules.

**Agreement, with a sharpening.** Our retry correctness is good. The corpus
makes clear retry is a *safety net*, not the limiter: if we ever depend on 429
retries to shape throughput (as a `rate: 3.0` bucket would, per finding 1), we
are in the regime chamlis warns about.

Recommended action: emit a metric/backpressure signal when 429 retries exceed a
threshold, so a mis-sized budget is visible instead of silently absorbed.

**Impact: Medium.**

---

### 11. Per-endpoint errors are undocumented; the error catalogue is non-exhaustive

**Claim.** The published spec documents only success responses, and the official
error list is not mapped to endpoints, so clients must treat unknown 4xxx codes
as valid game rejections.

**Evidence.** Mr. Hemlock, 2025-01-07: "All of the endpoints in the Stoplight
page only show 200 returns. But I know that endpoints will return specific
errors. … Should I just assume that anything that isn't a token issue is just
going to be a generic 400 error?"
— https://discord.com/channels/792864705139048469/817179355439562753/1326326283692675185

Leaf, 2025-01-07: "this is a list of all the errors, though not linked to
endpoints https://docs.spacetraders.io/api-guide/response-errors"
— https://discord.com/channels/792864705139048469/817179355439562753/1326334458135318592

Classification: other maintainer/community statement; consistent with the
bundled spec, which attaches no error codes to operations.

**Our design.** `GameplayError` maps a handwritten, explicitly non-exhaustive set
of codes to types and sends unknown codes to `:other`, preserving `code`,
`message`, and `data` (`lib/spacetraders/api/gameplay_error.ex:33-53`). ADR 0003
records that error codes are deliberately not codegenerated
(`docs/adr/0003-hand-rolled-api-client-with-codegen.md:5`).

**Agreement.** Our design already does the right thing. The corpus confirms the
risk is permanent, not a documentation gap that will close.

Recommended action: keep the raw envelope on every `GameplayError` (already
done) and add an observability counter for `:other` codes so new/hidden codes
surface from production rather than from the spec.

**Impact: Medium.**

---

### 12. Two token kinds: AccountToken mints, AgentToken acts

**Claim.** Only the AgentToken authorizes gameplay and `/my/*` reads; sending an
AccountToken yields a subject-claim rejection (4105).

**Evidence.** chamlis, 2025-03-06: "there are two tokens to track now: the agent
token, for registering agents, then the individual agent token, for issuing api
requests on behalf of an agent"
— https://discord.com/channels/792864705139048469/1106265069630804019/1347296377541103667

Banseljaj, 2026-09-14 (live 4105): `Token has an invalid subject claim. Expected
"agent-token" but received account-token.`
— https://discord.com/channels/792864705139048469/817179355439562753/1548954269149831179

Classification: chamlis statement + live observation.

**Our design.** ADR 0006 stores the encrypted AccountToken used **only to mint**
and per-Agent AgentTokens for game actions
(`docs/adr/0006-game-secrets-in-db-not-env.md:3`); `CONTEXT.md` defines Account
versus Agent authority the same way (`CONTEXT.md:9-31`).

**Agreement.** The token split is exactly right, and the corpus gives a concrete
error signature (4105) worth normalizing to a typed `:wrong_token_subject`
error, which our map currently sends to `:other`.

Recommended action: add code `4105` to `GameplayError`'s map as a
credential-misuse type so a misrouted token is diagnosable.

**Impact: Medium.**

---

### 13. Contracts are a minor, luck-dependent income stream

**Claim.** Contracts are useful early but are a small and noisy share of profit
later; some lose money by design.

**Evidence.** chamlis, 2026-06-02: "end of reset, contracts are usually 1% or
less of overall profit for me"
— https://discord.com/channels/792864705139048469/852291054957887498/1511505592638771270

chamlis, 2025-01-08: "you sort of have to accept that some contracts will lose
you money, some will lose a lot of money, but on average you usually come out on
top"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326406135653072977

chamlis, 2025-01-08: "it's almost always better to just buy the goods for the
contract and deliver those"
— https://discord.com/channels/792864705139048469/1106265069630804019/1326406398069833739

Classification: chamlis statement.

**Our design.** Contract acceptance is guarded by `StandingAuthority` and a
hard-constraint check, and acceptance estimation uses current listings
(`lib/spacetraders/fleet_contracts.ex:71-105`, `:229-239`); the game enforces one
active contract (finding 2).

**Agreement / tuning signal.** Our design is more cautious than the game
requires. Given contracts are ~1% of late profit, heavy machinery spent
optimizing contract selection has low ceiling; the risk is over-engineering, not
under-engineering.

Recommended action: keep contract handling conservative but explicitly
low-priority in the default Strategic Priority ordering; do not let a marginal
contract outrank a market trade for the same Ship.

**Impact: Medium.**

---

### 14. No player-to-player trade; interaction is market contention only

**Claim.** Agents cannot transfer goods or credits to each other; player
interaction is limited to competing over markets (and gates), which is why PvP
combat is not implemented.

**Evidence.** chamlis, 2026-03-06: "you can't trade between players. If you
could, that could be exploited to transfer wealth between agents"
— https://discord.com/channels/792864705139048469/792864705139048472/1479406498084814908

chamlis, 2024-12-17: "player interaction is solely getting in someone else's way
by making a profitable trade before they can, or, late game, intentionally
tanking markets"
— https://discord.com/channels/792864705139048469/1106265069630804019/1318398551667118191

chamlis, 2026-03-04 (Q&A): "There's now a new ShipNotValidTargetError for
shooting at player owned ships."
— https://discord.com/channels/792864705139048469/792864705139048472/1478724950071185490

Classification: chamlis statement; the 2026 quote is from a maintained Q&A.

**Our design.** `CONTEXT.md` models Shared World State as "mutable game state
that may be changed by other Agents" (`CONTEXT.md:153-155`) but defines no
inter-agent transfer path; the fleet vocabulary is explicitly single-Agent
(`CONTEXT.md:98-99`).

**Agreement.** No gap. The corpus confirms there is no cross-Agent coordination
API to design for, and that market contention is the entire PvP surface, which
justifies treating Market Signal and fresh listings as the competitive
intelligence that matters.

**Impact: Medium.**

---

### 15. Market composition is fixed per reset; trade volume predicts volatility

**Claim.** Which goods a market trades is fixed for the reset, but prices move as
players trade, and a market's `tradeVolume` indicates how volatile its prices are.

**Evidence.** chamlis, 2025-07-06: "the goods a particular market trades in is
fixed throughout a reset"
— https://discord.com/channels/792864705139048469/1106265069630804019/1391524744737849415

chamlis, 2025-08-30: "eventually, the price you can sell will be less than what
you can buy for, resulting in a loss"
— https://discord.com/channels/792864705139048469/1106265069630804019/1411388826349342890

chamlis, 2024-10-27: "the quantity doesn't really change the amount the price
increases, so it's less efficient to buy less of something if you could have
bought more, with the caveat that markets also have purchase volumes"
— https://discord.com/channels/792864705139048469/1106265069630804019/1300166143989780500

Classification: chamlis statement; `tradeVolume` volatility is also stated in
the bundled spec (`priv/spec/models/MarketTradeGood.json`).

**Our design.** `Candidate Trade Route` captures source/destination price and
observation time, and `Market Trading Job` "reconciles live prices before each
purchase and sale" (`CONTEXT.md:203-212`). `Intelligence.observe_market/4`
persists fresh listings (`lib/spacetraders/intelligence.ex:130-137`).

**Agreement.** The "composition fixed, prices volatile" split maps cleanly onto
our design: exports/imports are stable intelligence, prices are volatile
observations. Ensure `tradeVolume` and supply/activity signals are retained as
Market Signal so route ranking can prefer resilient markets, since thin markets
are where a strategy's own trades destroy its spread.

Recommended action: persist `tradeVolume` per listing observation (not just
price) and use it to discount high-frequency strategies on thin markets.

**Impact: Medium.**

---

### 16. Ship wear is real but bounded: engine up to 1.5x travel time, reactor +5s cooldown

**Claim.** Condition degrades with use and materially slows ships (engine wear
multiplies travel time up to 1.5x; reactor wear adds at most ~5s of cooldown),
but yield per extraction is unaffected.

**Evidence.** SafPlusPlus, 2024-12-14: "it works as a multiplier on the distance
traveled, which maxes out at 1.5 for a fully worn out engine"
— https://discord.com/channels/792864705139048469/852291054957887498/1317488870199394365

SafPlusPlus, 2024-12-14: "the effect of reactor wear on my mining drones is a
max addition of 5 seconds of reactor cooldown time (going from 70 sec to 75
sec) … (I didn't spot a decrease in yield per extraction…)"
— https://discord.com/channels/792864705139048469/852291054957887498/1317496218028347412

SafPlusPlus, 2024-12-14: "somewhat linearly correlated to the amount of transits
navigated"
— https://discord.com/channels/792864705139048469/852291054957887498/1317439149481005056

Classification: other maintainer, controlled self-reported measurement
(non-chamlis).

**Our design.** `CONTEXT.md` distinguishes **Condition** from **Integrity**
(`CONTEXT.md:315-316`) and lists frame/reactor/engine under Ship Readiness
(`:293-294`), but no policy consumes condition to adjust travel time or cooldown
estimates.

**Agreement / possible gap.** If the app surfaces ETA or cooldown, a worn ship
makes those numbers optimistic by up to 50% on travel. This is a real modelling
gap for planning, but condition is repairable and the maintainer says he never
approaches 50% wear in a reset (2025-03-17:
`https://discord.com/channels/792864705139048469/1106265069630804019/1351328427483074581`),
so the operational impact is low.

Recommended action: note the 1.5x / +5s bounds as planning caveats in
`CONTEXT.md`; only model wear in ETA after actually observing degraded ships.

**Impact: Low-medium.**

---

### 17. Waypoint traits beyond MARKETPLACE/SHIPYARD are flavour

**Claim.** Most Waypoint traits have no mechanical effect; only marketplace and
shipyard traits matter operationally.

**Evidence.** chamlis, 2024-10-13: "right now, you are correct that the only ones
that are really useful are for markets and shipyards"
— https://discord.com/channels/792864705139048469/1106265069630804019/1295051524904452218

(in response to a beginner asking whether breathable-air/radioactive traits
matter) — https://discord.com/channels/792864705139048469/1106265069630804019/1295051405211467929

Classification: chamlis statement.

**Our design.** `CONTEXT.md` defines **Waypoint Modifier** with caution styling
and forbids inferring severity (`CONTEXT.md:70-76`), and **Waypoint Intelligence**
(`:68-70`). Traits drive marketplace/shipyard candidate selection in
`Intelligence.marketplace_waypoints/2` (`lib/spacetraders/intelligence.ex:214`).

**Agreement, minor.** Our caution around modifiers matches the maintainer's
"mostly flavour" stance, and we correctly avoid inventing severity. The risk is
UI noise: surfacing decorative traits as if they were actionable.

Recommended action: keep decorative traits visually secondary to
MARKETPLACE/SHIPYARD; do not block or rank plans on them.

**Impact: Low.**

---

### 18. The game *is* writing the client; the challenge is API budgeting, not actor behaviour

**Claim.** SpaceTraders is an idle-game-shaped automation exercise whose real
difficulty is budgeting limited API requests and tracking information, not
simulating clever actors.

**Evidence.** chamlis, 2024-12-20: "The game itself isn't particularly deep. The
only way to make a lot of money is by trading … Most of the challenge in the
game isn't in actor behaviors, but rather in budgeting a limited number of API
requests per second."
— https://discord.com/channels/792864705139048469/1106265069630804019/1319509708234690650

chamlis, 2024-12-20: "It's more like: 'I can only make ~120 requests/min, which
ships should I control at this instant'"
— https://discord.com/channels/792864705139048469/1106265069630804019/1339321236551106664

chamlis, 2025-01-16: "This is not the same sort of automation as it is in
factorio. More like the automation of an idle game."
— https://discord.com/channels/792864705139048469/1106265069630804019/1329311146964156469

chamlis, 2025-12-29: "the rate limit is intended to encourage players to track
information, which, honestly, is most of the game"
— https://discord.com/channels/792864705139048469/1106265069630804019/1455328194432602214

Classification: chamlis statement, repeated across a year.

**Our design.** ADR 0010 builds a heavy planning/allocation runtime
(`docs/adr/0010-autonomous-runtime.md:29-46`) on top of the Evidence/API Capacity
boundary; ADR 0004 calls LiveView the "initial Mission Control adapter"
(`docs/adr/0004-liveview-as-control-surface-no-cli.md:4-5`).

**Tension, not contradiction.** There is a real product tension to name: the
maintainer values API-efficient information tracking over elaborate actor
behaviour, yet our architecture is a large multi-layer planner. The corpus
supports that trade only if the planner's output *reduces* request pressure
(better prioritization, fewer redundant reads). If the runtime increases call
volume, it works against the game's core constraint.

Recommended action: make "does this feature reduce or increase API requests per
credit earned?" an explicit design question in ADR reviews; keep Operational
Intelligence as the first-class product surface rather than an implementation
detail.

**Impact: Medium** (framing; guards against over-building).

---

## Corpus Gaps And Unknowns

- **No thread replies and no forum posts.** The corpus captures only top-level
  channel messages; forum channels (`suggestions`, `issues-forum`,
  `share-your-app`) were unreachable (`README.md`, "Coverage and known gaps").
  Any maintainer decision made in a forum thread is invisible here.
- **`general-chat` stops at 2026-03-04** due to a Discord pagination boundary;
  it covers only the last ~6 months of the 2-year window. Long-run historical
  claims therefore lean on `chamlis.jsonl`, `beginner-help`, `rust`, and
  `game-mechanics`.
- **No user IDs and display-name changes.** People are matched by display name;
  one person can appear under multiple names (`README.md`). Attribution of
  non-chamlis statements is best-effort.
- **Numbers are reset-scoped and empirical.** Fuel multipliers, contract
  profitability (~1%), and mining break-even come from live play in specific
  resets. They are maintainer-stated intent but should still be treated as
  observed, not contractual.
- **Unresolved mechanics with no corpus answer:** whether module install/remove
  requires a docked ship at a Shipyard; the exact aggregate power/crew
  validation formula; what happens when removing a capacity module would exceed
  the reduced capacity; and whether duplicate-module removal is still
  inventory-lossy (see `docs/research/phase-3-5-ship-outfitting-mechanics.md`).
  The corpus did not settle any of these.
- **No explicit ToS or "spirit of the game" document.** The nearest thing is
  chamlis saying multi-agent coordination "probably [is] an unfair advantage if
  they coordinate too much" (2024-12-20:
  `https://discord.com/channels/792864705139048469/1106265069630804019/1319521129240727595`)
  and that he disabled cross-agent market aggregation because "that does feel
  like cheating" (2025-01-31:
  `https://discord.com/channels/792864705139048469/1106265069630804019/1334799544944431196`).
  There is no written rule to cite; treat this as maintainer convention.
