# Read-independent simulator economics

Issue #787 extends the private **`world-control/v1`** implementation with
`economic_model = stock-scheduled/v1`. This supersedes #780's economics-only
unsupported/read-driven declarations in [world controls](world-controls.md).
Private implementation, world fixtures and authoritative exports stay private.

## Supported contract

`economic_tick` settles production and market price recovery at 1800-second
world-time boundaries for every nonempty Market, including unobserved Markets.
`inspect.next_event` exposes the earliest supported event. The class priority is
20, after Arrival (10); same-class Markets sort by symbol. World events settle
before the advance response and before the coordinator releases bot wakes.
No chart/rival class is added by this slice; priority 30 remains available for it.

Advance must stop at each due instant. Crossing an earlier event or supplying an
insufficient same-time event budget returns 409 with no time/state change.
Existing integer-time, step, event-count and horizon bounds remain. Catch-up
processes each event boundary without silently truncating production backlog.
An accepted timestamp can be retried after a lost response without applying its
events twice; inspect/export first when the outcome is uncertain.

Market reads do not advance economics. Fleet mutations still change stock,
prices, credits and Cargo through existing gameplay rules, but cannot trigger
elapsed-time progression. Extra reads still consume normal game API quota.
Matched initial worlds, external streams and successfully executed Fleet
mutations/times must produce equivalent economic state despite different read
schedules. Different Fleet actions may legitimately produce different outcomes.

## Rules and credibility

The selected model retains the fork's stock production, ambient input supply,
input-limited output, exchange restocking, stock-derived supply, tier repricing
and discrete price-recovery rules. It does **not** switch to the optional pricing
model or invent newly calibrated production/rival distributions. Recovery is
evaluated at scheduled Market instants; action-relative fractional recovery
intervals remain, with no hidden recovery on an off-phase trade.

The private rules document retains exact formulas and source/history references.
Historical quotes, distributions and delivery observations are provenance, not
proof of calibrated hidden production or rival rates. This repair establishes
read-independent model progression, not exact live-economic predictions.
Unsupported-mechanism-dependent rankings remain provisional; close or
uncertainty-sensitive comparisons remain inconclusive under specification #677.

## Evidence and remaining coverage

Bounded real-HTTP regressions compare authoritative exported game state and
Market Listings across sparse/dense reads with matched mutations, preserve a
changed-action divergence control, and demonstrate the old read-phase artifact
as an explicit negative control. They also check no-read production, price
recovery, catch-up, same-time Arrival order, atomic rejection and lost-response
retry. Compare economic state, not full export hashes: request logs, quota state
and preceding-request ordinals legitimately differ with observation schedules.

Coverage remains incomplete. Rival charting, Cooldown, Survey/Contract expiry
and reset remain unsupported scheduled classes in this slice. No application/PG
quiescence, whole-app recovery, artifact boot qualification, first-gate,
whole-period, protected-host capacity or live-game-equivalence pass is implied.
Earlier #778/#780 artifacts and proofs remain immutable, not relabeled. Parent
integration owns the combined public verification gate before any push.
