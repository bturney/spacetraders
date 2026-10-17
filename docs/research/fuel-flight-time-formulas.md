# Fuel and flight-time formulas (research for "Verify the game's fuel and flight-time formulas")

Question: are SpaceTraders fuel and flight-time deterministic, and exactly what are they, so trade
selection can rank by estimated net credits per Ship-hour?

Short answer:

- **Fuel (CRUISE, in-System navigate): deterministic and exact.** `fuel = max(1, round(d))`.
  It matched 7,946 of 7,946 real flights. It does not depend on condition. A Ship whose frame has
  `fuel_capacity = 0` (probes) consumes 0 fuel per flight. That matched 1,539 of 1,539 probe flights.
- **Time: deterministic, but the wiki formula only holds at engine condition 1.0.**
  `t = round(15 + round(max(1, d)) * 25 / engine.speed * m(engine.condition))` seconds, with `m(1) = 1`.
  At condition 1.0 the wiki formula matched 599 of 599 flights exactly. Below 1.0 the game slows
  the Ship by up to about 21% at condition 0.89, and the wiki formula then underestimates by up to
  142 s (16.7%). `m` is a smooth function of **engine** condition only. Frame condition, cargo,
  crew and fuel have no effect. The closed form of `m` is not published. The best empirical fit
  is `m = 1 + 2.52x / (1 + 2.78x)` with `x = 1 − engine.condition`. Fitted on the ORBITALIST
  generations and tested on Generation 5, it gives the exact second on 97.6% of flights and
  ±1 s on 99.85%.
- **Not settled by the snapshot:** the BURN, DRIFT and STEALTH multipliers and fuel, warp, and
  jump cooldown. The snapshot holds only CRUISE in-System navigation, no Ship had a warp drive,
  and no jump was recorded. The exact closed form of `m` is also unsettled. An experiment for
  these is proposed at the end.

## Sources

1. SpaceTraders wiki, [Travel, Fuel and Time](https://github.com/SpaceTradersAPI/api-docs/wiki/Travel-Fuel-and-Time),
   wiki repo HEAD `7983d08` (2025-05-01). It is community-compiled ("compiled from information
   supplied by our discord users"). It says values marked `*` "have not been confirmed on 2.1 or
   later".
2. Bundled OpenAPI contract `priv/spec/SpaceTraders.json` (v2.3.0) and `priv/spec/models/*.json`.
3. SpaceTraders changelog, [March 10, 2024 (v2.2)](https://docs.spacetraders.io/resources/changelog):
   "ships will perform worse when their condition is low, but will never become inoperable".
   Condition is "a float between 0 and 1" that "will degrade over time and with adverse ship
   events".
4. The scrubbed production snapshot `~/spacetraders-snapshots/20261016T182711Z/` (not in the
   repo). It was restored into a throwaway local database, queried, and dropped.

## What the primary sources say

| Item | Wiki (community) | OpenAPI v2.3.0 |
| --- | --- | --- |
| Distance | Euclidean `sqrt((x1−x2)² + (y1−y2)²)`, "generally … rounded before it is used" | Not stated |
| Fuel CRUISE / STEALTH | `round(d)`, minimum 1 | "consume the necessary fuel … based on the distance" (`navigate` description); no formula |
| Fuel DRIFT | `1` | — |
| Fuel BURN | `2 * round(d)`, minimum 2 | — |
| Time | `round(round(max(1,d)) * multiplier / speed + 15)` s | `ShipNavRoute.arrival` is the authoritative ETA; `ShipEngine.speed`: "the higher the speed, the faster" |
| Navigate multiplier | CRUISE 25, DRIFT 250, BURN 12.5, STEALTH 30\* | — |
| Warp multiplier | CRUISE 50, DRIFT 300\*, BURN 25\*, STEALTH 60\* | `warp` consumes fuel; no formula |
| Jump | Cooldown `round(15 + 0.3 * d)` over System distance; antimatter | `jump`: "A unit of antimatter is purchased and consumed"; instantaneous |
| Condition | Not mentioned | `ShipComponentCondition` exists; the changelog says low condition degrades performance |

The contract defines the fields (`ShipFuel.consumed.amount` and `timestamp`,
`ShipNavRoute.departureTime` and `arrival`, `ShipEngine.speed`, `ShipNavFlightMode` enum
`DRIFT|STEALTH|CRUISE|BURN`, default CRUISE). It gives no formulas. The formulas exist only as
community observation, so the snapshot is the test.

Engine speeds have changed since the wiki's Components page was written. The wiki lists
Ion Drive II at 30. This game reports `ENGINE_ION_DRIVE_II` at 36 and `ENGINE_IMPULSE_DRIVE_I`
at 9. Always read `ship.engine.speed`; never use a component table.

## Snapshot test

### Data

- `authoritative_observations` rows for `get-my-ship` (22,065) and `get-my-ships` (48,587) were
  flattened into 119,239 Ship states. They were deduplicated by `(ship, nav.route.departure_time)`
  into **9,491 flights**.
- Each flight carries the origin and destination `x, y`, `departure_time`, `arrival`,
  `flight_mode`, `engine.speed` and `engine.condition`, and `fuel.consumed.amount` with its
  timestamp (always 0–158 ms after departure).
- The data was internally consistent. Every flight had exactly one arrival, one route and one
  speed. Every flight had a `consumed` record matching its departure. In 9,484 of 9,485 real flights
  `fuel.current` before minus after equals `consumed.amount`.
- 6 pseudo-flights were excluded. These are starting positions at registration or reset, where
  `departure = arrival` and distance is 0. That leaves **9,485 real flights**:

| Ship | Generation | Engine (speed) | Frame (fuel cap) | Flights |
| --- | --- | --- | --- | --- |
| HARDBARGAIN-1 | 5 | Ion Drive II (36) | Frigate (400) | 3,769 |
| HARDBARGAIN-2 | 5 | Impulse Drive I (9) | Probe (0) | 1,489 |
| ORBITALIST-1 | 3–4 | Ion Drive II (36) | Frigate (400) | 4,177 |
| ORBITALIST-2 | 3–4 | Impulse Drive I (9) | Probe (0) | 50 |

- All flights are **CRUISE** and in-System (`navigate-ship`; there are no `warp`, `jump` or
  `patch-ship-nav` attempts). Distances range from 0 (2,792 same-coordinate hops such as
  moon↔planet) to 735.
- Engine condition ranges from 1.0 down to 0.890. Condition changes only at a navigate
  (141 drops, averaging 0.0015–0.0044 each) and once at a dock (+0.087, a repair).

### Fuel

| Formula (CRUISE) | Frigate flights matched |
| --- | --- |
| `max(1, round(d))` (wiki) | **7,946 / 7,946** |
| `max(1, floor(d))` | 6,223 / 7,946 |
| `max(1, ceil(d))` | 4,241 / 7,946 |

- The minimum of 1 is confirmed: all 2,518 zero-distance frigate hops cost exactly 1.
- Rounding is to nearest. Half-way cases cannot occur because `sqrt` of an integer is never
  `n + 0.5`, so the half-rounding rule does not matter.
- Condition has no effect: fuel is exact from condition 1.0 down to 0.89.
- Probes (`fuel_capacity: 0`) report `consumed.amount = 0` on every flight, up to distance 735.
  They fly free. The repo's `SpaceTraders.Fleet.FuelReach.estimate/3` already implements the
  CRUISE rule above. It does not special-case zero-capacity frames.

### Flight time

Observed `arrival − departure_time` is whole seconds. On 385 flights it reads 1 ms short
(`n.999 s`), so compare with `round(...)`.

**Wiki formula at engine condition 1.0:** 599 / 599 flights exact. All four Ships contributed,
covering 37 distinct rounded distances and speeds 9 and 36. The time breaks down as follows:

- The 15 s constant is confirmed.
- The inner `round(max(1, d))` is required. With unrounded distance only 559 / 599 match.
- The outer rounding is to nearest. Ceiling gives 433 / 599 and floor gives 254 / 599.
- A zero-distance hop at speed 36 takes `round(15 + 25/36) = 16` s.

**Below condition 1.0 the wiki formula always underestimates** (residual ≥ 0, never negative):

| Engine condition band | Flights | Wiki exact | Wiki mean / max under-estimate |
| --- | --- | --- | --- |
| 1.0 | 599 | 100% | 0 / 0 s |
| 0.95 – <1.0 | 6,752 | 35.4% | 4.7 / 142 s |
| 0.90 – <0.95 | 1,804 | 28.5% | 12.1 / 125 s |
| <0.90 | 330 | 10.9% | 16.9 / 55 s |

The slowdown follows the formula below:

- Per condition value, `t` against `round(max(1,d)) * 25 / speed` is a straight line.
- Its intercept stays 15 s and only the slope scales. Fitted intercepts fall between 14.85 and
  15.32 s across 73 condition values with at least 20 flights, with ≈0.25 s residual, which is rounding noise.
- The slope `m` depends on **engine** condition only. Probe and frigate at the same condition
  give the same `m` (for example 0.94429 → 1.1219 against 0.94437 → 1.1217).
- Adding frame condition to the regression gives it a coefficient of about 0.
- Reactor condition and integrity were 1.0 throughout and could not be tested.
- Equal inputs give equal times: of 1,451 repeated `(ship, rounded distance, conditions)` groups,
  1,423 are identical. Of the other 28, 24 differ by 1 s, 2 by 2 s, 1 by 3 s and 1 by 9 s.

| Engine condition | 1.000 | 0.990 | 0.975 | 0.952 | 0.934 | 0.915 | 0.895 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Time multiplier `m` | 1.000 | 1.023 | 1.059 | 1.105 | 1.139 | 1.173 | 1.2015 |

Candidate forms for `m` (x = 1 − engine.condition), scored on all 9,485 flights:

| `m(x)` | Exact | Within ±1 s | Range |
| --- | --- | --- | --- |
| 1 (wiki) | 37.3% | 47.7% | 0 … +142 s |
| `1/e`, `1/e²`, `1/(2e−1)`, `(2−e)²`, `3−2e` | 41.7–65.5% | 56.3–88.6% | up to −19 … +79 s |
| `1 + 2.47x − 5.0x²` | 97.5% | 99.92% | −9 … +1 s |
| **`1 + 2.52x / (1 + 2.78x)`** | **98.3%** | **99.92%** | −10 … 0 s, RMSE 0.17 s |

**Holdout test:** the rational form was fitted on ORBITALIST (4,227 flights). The grid search
picked the same coefficients, 2.52 and 2.78. On Generation 5 (5,258 flights) it gives 97.6%
exact and 99.85% within ±1 s. 8 flights are off by 2–10 s, all on the probe, with a maximum
relative error of 0.8%.

The remaining ±1 s misses fall where the predicted value is close to `n.5`. The model is
therefore close but not the game's exact expression. That is good enough to rank trades per
Ship-hour (≤2.3% error on any flight). It is not good enough to promise an arrival second.

## Formulas to use

```text
d     = sqrt((x1−x2)² + (y1−y2)²)               # Waypoint coordinates (Systems for warp/jump)
rd    = round_half_up(max(1, d))
fuel  = 0                                       if frame fuel capacity == 0
      = max(1, round_half_up(d))                CRUISE (confirmed); STEALTH per wiki (unconfirmed)
      = 1                                       DRIFT (wiki, unconfirmed)
      = max(2, 2 * round_half_up(d))            BURN (wiki, unconfirmed)
x     = 1 − ship.engine.condition
m     = 1 + 2.52x / (1 + 2.78x)                 empirical; exactly 1 at condition 1.0
secs  = round_half_up(15 + rd * mult / ship.engine.speed * m)
mult  = navigate: CRUISE 25 (confirmed); BURN 12.5, DRIFT 250, STEALTH 30 (wiki, unconfirmed here)
        warp:     CRUISE 50, DRIFT 300, BURN 25, STEALTH 60 (wiki, unconfirmed here)
jump  = instantaneous; cooldown round(15 + 0.3 * system distance) s (wiki, unconfirmed here)
```

The game's `nav.route.arrival` and `fuel.consumed` in the navigate response are authoritative.
Estimates are for ranking only.

What to do about condition when ranking:

- Read `engine.condition` from the latest authoritative Ship state; never assume 1.0.
- At this fleet's observed condition (0.89–1.0) the slowdown is 0–21%.
- It applies to the distance term only, never to the 15 s constant.

## What the snapshot cannot settle

1. BURN, DRIFT and STEALTH time multipliers and fuel (no non-CRUISE flight was recorded).
2. Warp fuel and time (no warp drive was fitted).
3. Jump cooldown and antimatter cost (no jump was recorded).
4. The exact closed form of `m` (the empirical fit is within ±1 s on 99.9% of flights).
5. Whether reactor condition, or component integrity below 1.0, also slows the Ship (both were
   1.0 throughout).

### Proposed task ticket (not created): "Measure non-CRUISE flight modes on an authorized live leg"

- **Type:** `wayfinder:task`. It needs Operator authorization for live mutations.
- **Goal:** settle items 1 and 4 above.
- **Steps:**
  1. Pick a frigate in orbit and two Waypoints about 40–80 units apart, both selling FUEL, in
     its current System.
  2. Record `engine.condition` and `engine.speed` before each leg.
  3. Fly the same leg once each in CRUISE, BURN, STEALTH and DRIFT. Use `PATCH /my/ships/{s}/nav`
     to set the mode before orbit or navigate. Do not change the mode while in transit: the
     changelog says that costs extra fuel.
  4. Keep each raw navigate response: `nav.route`, `fuel.consumed` and `events`.
  5. Re-run one leg in CRUISE straight after any condition drop, to add a point to `m`.
- **Cost bound:**
  - About 4 legs plus 1 DRIFT leg. DRIFT costs 1 fuel but takes about 10× CRUISE time (around
    10 min at speed 36 for 80 units).
  - Fuel is at most `2 × 80` per BURN leg.
  - There is no cargo or market risk.
- **Done when:** observed fuel and arrival for each mode are compared against the formulas above.
  Fold the result into this note.
- **Out of scope:** warp and jump (needs a warp drive or a jump gate route; a separate decision).

## Reproduce

1. Restore `scrubbed.dump` into a throwaway database per the snapshot README.
2. Flatten Ship states. Use `facts->'response'` for `get-my-ship` and
   `jsonb_array_elements(facts->'response')` for `get-my-ships`.
3. Group by `(symbol, nav.route.departure_time)`.
4. Take `x, y` from `nav.route.origin` and `nav.route.destination`, `engine.speed` and
   `engine.condition` from the first observation of the flight, and `fuel.consumed.amount`
   where its timestamp is within 2 s of departure.
5. Drop the database afterwards.
