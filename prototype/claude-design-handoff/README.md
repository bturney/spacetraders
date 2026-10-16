# Handoff: Mission Control redesign

## Overview
This is a new Mission Control for the SpaceTraders bot (repo `bturney/spacetraders`, Phoenix 1.8 LiveView with Tailwind and daisyUI). It is a watch-only screen. In about 60 seconds, someone who has never played should be able to tell whether the fleet is going well, what each Ship is doing and why, and what happens next. It uses game vocabulary instead of engine internals. Nothing on the screen asks the operator to act.

## About the design files
`Mission Control.dc.html` is a **design reference built in HTML**: a clickable prototype that shows the intended look and behaviour. It is not production code. To view it, open it in a browser; it needs `support.js` next to it. Rebuild it in the existing app, in `lib/spacetraders_web/live/` using LiveView, HEEx components and Tailwind, following the codebase's own patterns. A good starting point is to replace `mission_control_live.ex`. The prototype's simulation (`step()`, `makeFleet()`) is a stand-in for real data from the engine and the database. Do not port it.

## Fidelity
**High fidelity.** Colours, type, spacing, copy and motion are final. Match them, expressed as Tailwind or daisyUI theme tokens.

## Principles (non-negotiable, from the brief)
1. It's a game first. Prefer visual forms (route bars, countdowns, charts, motion) over text.
2. Game vocabulary. Write "Hauling 20 Ammunition F47 → E45", never "Commitment 8483" or "Decision Episode".
3. Nothing needs the operator. No alerts and no action prompts. A stuck Ship is a tuning problem to analyse later.
4. Honest numbers. Estimates are labelled "est." and use "~" when based on old prices. Unknown is never shown as 0: say why, and when it will be known. Hide unknowns that don't change understanding.
5. Fast and calm. Live updates must never move the layout. Use tabular numerals, fixed-width time cells, and overlays positioned absolutely.

## Screens and views
One connected experience. On phone each section is its own screen, with bottom tabs **Glance / Ships / Records**. On desktop it is two columns.

### Layout
- **Phone (390 × 844, the lead device):** header (one line, no wrapping), a content area that scrolls, and a tab bar (min height 48px per tab, an 18×3px bar above the active tab label in cyan).
  - The **Glance** screen must fit **without scrolling** in every situation, including 120 Ships and the longest health reason. This is verified at 693px of content height.
  - Card padding 11px 14px, gap between cards 10px, content padding 10px 12px 12px.
- **Desktop (fluid up to 1360px wide, min height 860):**
  - Left column, 400px fixed: Plan health, Credits, Records.
  - Right column, flexible: Ships in motion, then the Ship list. Opening a Ship replaces both with the Ship view.
  - Gap 20px, content padding 22px 24px 28px.
- **Wall TV:** the desktop layout should be readable from a distance. Never go below the type sizes listed here.

### Header
- Logo mark (a 22px cyan ring with a 6px dot), "Mission Control" (17px on phone, 21px on desktop, weight 600), and a subtitle with the situation label (12px, dim, ellipsized).
- Badge: "REAL DATA" (green outline) or "SAMPLE DATA" (yellow outline). On phone it reads "REAL" or "SAMPLE". Font: mono 10px, letter-spacing .12em.
- Right side: **countdown to the next sale**, i.e. the soonest arrival of any trading or busy trader. Mono 15px, weight 500, e.g. "1:35".
  - Below it: "next sale · +820 est." (with "~" in front when prices are old).
  - If no trade is under way: "—" and "no sale under way", both dim.

### 1. Plan health card
- **Four states, each with a colour:**
  - green **On plan**
  - yellow **Small setback, recoverable**
  - red **Off plan, real blocker**
  - grey **Can't tell right now**. This one is visually distinct: a hollow dot with a dashed border and no glow.
- **Layout:** a 14px dot that glows in the state colour, the label (20px desktop / 18px phone, weight 600, in the state colour), and "PLAN HEALTH" (mono eyebrow, right-aligned).
- Below: a one-line reason (15px / 14px, line-height 1.35).
- Card background is the state colour at 9%; the border is the state colour at 35%. Both transition over 0.6s.
- **Reasons per situation** (exact copy is in `health()` in the prototype):
  - **Healthy:** "A trade lands every 3–4 min and earnings are at the usual pace."
  - **Busy:** "14 trades in the last hour netted only +2,848 (usual ~13–15k). One Lab Instruments trade expected +860 and lost 8,000."
  - **Waiting:** "…waits at C41 and looks again in {countdown}. That's the plan working." The state stays green.
  - **Stuck:** "HARDBARGAIN-1 has been stuck at G49 for {n} min without fuel to leave. It retries on its own every 90 s."
  - **Old information:** "Prices are 44 min old (trusted up to 30). The probe is 2 markets behind and catches up in ~{n} min, around {HH:MM}." When the probe catches up, the state turns green with "Prices are fresh again…".

### 2. Credits card
- Eyebrow "CREDITS", with "whole game · 5 days" on the right.
- **Big number:** 44px desktop / 34px phone, weight 600, tabular numerals.
  - It **counts up** towards the new total (eases about 18% of the gap per 200ms).
  - It turns green while a sale's pop-up is showing.
  - A "+1,340" float sits beside it and fades in then out.
- **Rate line:**
  - Mono 15px, e.g. "~14k cr/h", followed by a caption such as "usual pace (13–15k)".
  - Then "· game avg 22.5k/h", computed as (credits − 172,000) ÷ hours since 11 Oct.
  - In the busy situation the rate is "+2,848", in yellow, and the game average is hidden.
- **Growth line:** an SVG area chart over the whole game (green line plus a 12% green fill). It is 72px tall on desktop and 46px on phone. Labels read "11 Oct · 172k" and "now · 2.87M". The last point follows live credits.
- **Link at the bottom:** "Where do our credits come from?" plus "GRAFANA ↗", which opens the credits Grafana dashboard.

### 3. Ships in motion
- **2 Ships:** one card per Ship, in a grid with auto-fit and minmax(280px, 1fr). Each card has:
  - the name (mono 12) and a status chip
  - the time on the right: mono 24px, with a caption "to arrival", "looks again" or "next retry"
  - the phrase, e.g. "Hauling 20 Ammunition · +820 est."
  - a **route bar**: from-code, an 8px track filled to the progress point, a 12px rotated-square marker that glows in the status colour, then the to-code. Width and position transition over .25s linear.
  - Waiting and stuck Ships show the waypoint and a draining countdown bar, with no marker.
  - On arrival, the time is replaced by "+1,340 / sold just now" in green (or red for a loss) for 4.5s, and the card border tints.
- **120 Ships:** a grid of 120 cells (20 columns on desktop, 24 on phone). Each cell is a square tinted in its status colour at 18%, filled from the bottom by journey or countdown progress; stuck Ships are filled solid. Cells get an outline when a sale lands. Clicking a cell opens that Ship.
  - Below: a legend with counts per status.
  - Desktop only: "Landing next", the 3 soonest arrivals as compact route rows.

### 4. Ship list
- Ordered by name, in natural number order.
- Filter chips for "All" plus each status present, each with a coloured dot and a count.
- **Row grid areas:**
  - Desktop: `name status cargo route time est`, columns `128px 140px 1.1fr 1.2fr 70px 92px`, with a header row "Ship / Status / Doing / Route / Time / Profit (est.)".
  - Phone: `'name status' 'cargo est' 'route time'`, columns `1fr auto`.
- **Cells:** name (mono 13), status chip, phrase (14), mini route bar (5px track, 8px marker), time (mono 13 plus a 10px caption), estimated profit (mono 13; "~" and a yellow "old prices" note when prices are stale).
- When a sale lands, the time cell shows "+1,340 sold" and the row background tints for 4.5s.
- Must work for both 2 and 120+ Ships; the list scrolls with the page.

### 5. Ship view (the "why")
- "← All Ships" back link.
- **Header card:**
  - name (mono 20, weight 600), role ("Trader", or "Probe · checks market prices, carries no cargo"), status chip
  - phrase (19px) and a big time (mono 34) or the sold flash
  - a big route bar (10px track, 16px marker)
  - facts: Cargo, Bought at, Expected (est.), or At / Stuck for / Retries so far
- **WHY card:**
  - A plain sentence, 17px, line-height 1.5. Example: "Bought 20 Ammunition at F47 for 1,846 each to sell at E45 for about 1,887 each, expecting about +820. It chose this over Fertilizers G49 → E46 (+560) and Hydrocarbon C41 → G49 (+520) because it pays the most."
  - "What it compared": horizontal bars scaled to the largest value. The chosen option is green and tagged "CHOSEN"; the others are muted. For waiting Ships, the bars are red negatives labelled "Best trades it knows, after fuel (none taken)".
  - Caveats as small diamond bullets, e.g. "The E45 price is 28 min old" and "Estimates leave out fuel". They are yellow when they matter, such as old prices.
- **RECENT TRADES card:**
  - Each row has the route label and "exp +980 → +1,340".
  - A **dumbbell** chart: a centre zero line, a hollow dot for expected, a filled dot for actual, and a connecting segment. Colours: green if it beat the estimate, yellow if it fell short, red if it lost money.
  - A "+360 vs est." delta and an optional note, such as "Paid 59,700 · sold 61,040".
  - Rows for skipped buys show only text, e.g. "planned 2,985 · was 3,154".
- **Grafana link card** (cyan-tinted): "Dig deeper / Do old prices cost us money?" plus "GRAFANA ↗".

### 6. Records
- **Best single trade:** +43,620 (32px, green), "Lab Instruments C41 → A4 · 11 Oct".
- **Most valuable goods:** bars for Ship Parts 469k, Medicine 390k, Fabrics 380k, Electronics 303k. The leader is solid yellow; the others are yellow at 60%.
- **Trades completed:** 1,277, live. Sub-line: "3.13M trading profit before fuel · 397k spent on fuel · 626 buys skipped because prices rose".

### 7. Grafana mocks (two)
In production these are links to real Grafana. Use `SpaceTradersWeb.GrafanaLink.url/2`:
- "Do old prices cost us money?" uses the `intelligence_api_capacity` family.
- "Where do our credits come from?" uses `economics_capital`.

Each dashboard should be built or provisioned to answer its question, as shown in the mocks. The prototype adds a strip at the top with "← Back to {Ship or Mission Control}" and the URL. In production, getting back means a dashboard link to Mission Control, carrying the Ship as a query parameter so it can be restored.
- **Old prices:**
  - text panel with the answer
  - bar gauge: fresh +120 vs 20–30 min +80
  - stat: 31 / 48 big misses used fresh prices
  - table: worst route, C41 → A4 Lab Instruments, +860 expected, −8,000 actual, 2 times
- **Credits:**
  - text panel with the answer
  - stats: Trading 3.13M, Fuel −397k (13%)
  - "No data" panels for Contracts, Charting and Ship buying
  - bars for income vs costs: Trading 3.13M, Fuel −397k, After fuel 2.73M

## Ship statuses (vocabulary)
| Status | Colour | Phrase example | Time shown |
|---|---|---|---|
| Trading | green | Hauling 20 Ammunition | to arrival |
| Busy, not earning | yellow | Hauling 20 Fabrics | to arrival |
| Waiting on purpose | violet | Waiting for a trade worth making | looks again (5 min loop) |
| Stuck | red | Low on fuel at G49, retrying · 12 min | next retry (90 s) |
| Scouting prices (probe) | cyan | Checking prices (· 2 markets behind) | to arrival |

## Interactions and behaviour
- **Navigation:**
  - Glance, Ships and Records tabs (phone only).
  - A row, card or cell opens the Ship view; back returns to where you came from (Glance or Ships).
  - Grafana links open the dashboard, and its back link returns.
- **Live events:**
  - When a sale lands: credits count up, a "+X" float appears beside the number, and the row or card flashes for 4.5s.
  - A **SOLD pop-up** appears at the bottom of the screen (above the tab bar on phone, 86px from the bottom; 24px on desktop).
    - Content: "SOLD" chip, "+1,340" in mono 16, then "Electronics at C41".
    - On phone the Ship's name is dropped, and the pop-up is at most the screen width minus 24px, with the text ellipsized.
    - With many Ships, sales are batched into at most one pop-up per 2.6s, showing the largest sale plus "+N more"; the credits float shows the total.
    - The pop-up fades and slides over .35s.
- **Countdowns** tick every second; route markers move continuously.
- **No layout shift:** time and number cells have fixed widths and tabular numerals, and pop-ups and floats are positioned absolutely.

## State and data needed (LiveView assigns)
- **Fleet totals:**
  - credits now
  - credits over time, for the growth line
  - earned in the last hour, plus the usual range
  - game average rate
  - trades completed
  - records
- **Plan health:** {state: green, yellow, red or grey; reason}. Derive it from the earning rate against the usual pace, stuck Ships, and data freshness (price age against the trust window of 30 min, and probe lag with its expected catch-up time).
- **Per Ship:**
  - name, role, status
  - from, to, depart and arrive times (or `at`), cargo (quantity and good), unit price, expected profit
  - for waiting Ships: next look; for stuck Ships: stuck since, next retry, retry count
  - the options it compared, with expected profit
  - caveats, such as price age and "estimates leave out fuel"
  - recent trades, each with expected, actual and an optional note
- **Pushing updates:** push them over PubSub. Interpolate the countdowns and bar positions on the client, using a small JS hook driven by depart and arrive times, so the server doesn't re-render every second.

## Design tokens
Mixing uses `color-mix(in oklch, C X%, transparent)`.

**Neutrals:**
- Page `oklch(0.12 0.01 245)`
- App background `oklch(0.155 0.012 245)`
- Panel `oklch(0.195 0.014 245)`
- Panel 2 `oklch(0.235 0.016 245)`
- Track `oklch(0.30 0.016 245)`
- Line `oklch(0.29 0.016 245)`, inner divider `oklch(0.26 0.016 245)`
- Ink `oklch(0.96 0.006 245)`, muted `oklch(0.76 0.016 245)`, dim `oklch(0.60 0.016 245)`

**Status colours:**
- Green `oklch(0.80 0.15 150)`
- Yellow `oklch(0.84 0.14 85)`
- Red `oklch(0.70 0.17 25)`
- Grey `oklch(0.72 0.01 245)`
- Cyan `oklch(0.80 0.12 215)`
- Violet `oklch(0.78 0.12 295)`

**Tints and borders:**
- Chip background: the status colour at 16%
- Bar fill: the status colour at 55% (waiting 35%, stuck 45%)

**Type:**
- Barlow (400, 500, 600, 700) for UI text; JetBrains Mono (400, 500, 600) for numbers, codes and eyebrows.
- Eyebrows: mono 10px, letter-spacing .14em, uppercase, dim.

**Shape:**
- Cards: radius 14, 1px line border.
- Inner cards: radius 10. Chips: radius 999.
- Device bezel in the prototype only.

**Grafana mock:** background #111217, panel #181b1f, panel border #2c3235; green #73bf69, orange #ff9830, red #f2495c, blue #5794f2; text #ccccdc.

## Sample vs real data
- **Real:** the "Healthy trading" and "Busy but not earning" situations (busy is the 12 Oct 23:00–23:55 window); the records; the Grafana answers; the HARDBARGAIN-1 Ammunition trade and the Electronics sale.
- **Sample:** "Waiting on purpose", "Stuck, recovering", "Old information", the 120-Ship fleet, and the extra recent trades. Their rows are tagged SAMPLE or SIM in the prototype.
- In production all data is real, so these tags go away.

## Out of scope
An interactive star map, manual controls, notifications, settings.

## Files
- `Mission Control.dc.html`: the prototype. Its controls at the top switch the situation, 2 vs 120 Ships, phone or desktop, and sim speed; they are not part of the design. Copy and logic are in the `<script data-dc-script>` class: `health()`, `vm()` and `detail()` hold all the user-facing strings.
- `support.js`: the runtime needed to open the prototype in a browser.
