# Spacetraders Design System
The visual and copy system for **Mission Control**, a watch-only screen for a SpaceTraders fleet that plays itself. An autonomous engine flies the HARDBARGAIN Ships between waypoints, buying goods cheap and selling them dear. Mission Control lets someone who has never played tell, within 60 seconds, whether it's going well, what each Ship is doing and why, and what happens next.

**Sources:** GitHub `bturney/spacetraders` (main): a Phoenix 1.8 LiveView app with Tailwind v4 and daisyUI; `lib/spacetraders_web/live/mission_control_live.ex` and `grafana_link.ex`. The system itself was derived from the redesign prototype `/Mission Control.dc.html`. The repo's existing UI was context only.

**Surfaces:** Mission Control (phone first, desktop, eventually a wall TV) and Grafana dashboards that are linked from it.

## Content fundamentals
- **Game vocabulary, never engine internals.** Write "Hauling 20 Ammunition F47 → E45", not "Commitment 8483 pursuing objective 0". Never show "Decision episode", "portfolio" or "EV".
- **Plain verb phrases** for what a Ship is doing: "Hauling 20 Fabrics", "Checking prices", "Waiting for a trade worth making", "Low on fuel at G49, retrying".
- **Why sentences** use the third person, past tense, and one sentence: what it chose, over which alternatives, and why. For example: "It chose this over Fertilizers G49 → E46 (+560) and Hydrocarbon C41 → G49 (+520) because it pays the most."
- **Nothing asks the operator to act.** No "needs attention", no calls to action, no alerts. A stuck Ship is described calmly, e.g. "It retries on its own every 90 s."
- **Honest numbers:**
  - Estimates say "est.", and get a "~" when based on old prices.
  - Unknown is shown as "—" or "No data", never 0.
  - A headline unknown says why and when it will be known: "catches up in ~9 min, around 14:20".
- **Fixed status vocabulary:** Trading · Busy, not earning · Waiting on purpose · Stuck · Scouting prices. Health is On plan · Small setback, recoverable · Off plan, real blocker · Can't tell right now.
- **Casing:** Sentence case throughout. Eyebrows are mono UPPERCASE. Ship names (HARDBARGAIN-1) and waypoint codes (F47) appear verbatim in mono.
- **Numbers:** Thousands separators (1,340); compact forms for big figures (2.87M, 469k). Signs are always shown: "+" and U+2212 "−". Rates are written "cr/h".
- **No emoji.** Unicode is used only for arrows (→, ←, ↗) and the ◆ bullet in caveats.
- **Tone:** calm, matter-of-fact, mildly playful through motion rather than copy. Data is tagged SAMPLE or REAL.

## Visual foundations
- **Mood:** a mature dark control room. It is cool and blue-grey (hue 245) and nearly flat, with colour reserved for meaning. It feels like a ship's instrument panel, not a sci-fi poster: no starfields, gradients or glow except on live markers.
- **Colour:**
  - Neutrals are a 9-step oklch ramp from 0.12 (page) to 0.96 (ink).
  - Five status hues share L≈0.78–0.84: green, yellow, violet, red and cyan, plus a grey for unknown.
  - Colour always means status or money. Tints come from `color-mix`: 16% for chips, 9% card background with a 35% border for state cards, and 55% for bar fills.
- **Type:**
  - Barlow (400–700) for words.
  - JetBrains Mono for every number, code, time and eyebrow, always with `tabular-nums`.
  - Credits are 44/34px; countdowns 34/24/13px; body 15/14px; the minimum size is 10px.
- **Cards:**
  - Radius 14, 1px line border, flat (no shadow), padding 11/14 on phone and 16/18 on desktop.
  - Inner cards have radius 10. Chips are pills (999).
  - The only shadow is on the SOLD toast.
- **Layout:**
  - **Phone:** a header, content that scrolls, and a fixed 3-tab bar (min height 48). The Glance screen never scrolls.
  - **Desktop:** a 400px left column (health, credits, records) and a flexible right column (motion, list), with a 20px gap and a maximum width of 1360.
- **Motion:** game-like but calm.
  - Route markers glide linearly; countdowns tick each second.
  - Credits ease upward (18% of the gap per 200ms); sold flashes tint for 4.5s.
  - The toast fades and slides over .35s and is batched to at most one per 2.6s.
  - Health colour transitions over .6s.
  - **Nothing shifts layout:** every number cell has a fixed width, and pop-ups are positioned absolutely.
- **Hover and press:** a panel goes to `--st-panel-hover` on hover; links go from cyan 0.82 to 0.90. There is no press scaling.
- **Imagery:** none. Visual interest comes from data forms: route bars, the fleet grid, growth lines, dumbbells.
- **Grafana:** its own palette (`--gf-*`), 2px radii and Inter. It is always entered and left through a back strip.

## Iconography
There is no icon set and no logo in the source. The mark is a 22px cyan ring with a 6px dot, built from plain CSS shapes. Unicode arrows (→ ← ↗) and the ◆ bullet serve as icons; status is carried by coloured dots and diamonds. If icons are needed later, use Lucide at 1.5px stroke. No emoji.

## Index
- `styles.css`: the entry point, a list of imports of the `tokens/` files (fonts, colors, typography, shape, motion).
- `guidelines/*.card.html`: specimen cards for the foundations.
- `components/`
  - **core:** Card, Eyebrow, StatusChip, DataBadge, Money
  - **live:** RouteBar, Countdown, SoldToast, CreditsTicker
  - **charts:** GrowthLine, CompareBars, Dumbbell, GoodsBars
  - **fleet:** HealthCard, ShipRow, ShipCard, FleetGrid
  - **grafana:** GrafanaPanel, GrafanaStat, GrafanaBackBar
- `ui_kits/mission-control/`: a phone click-through (Glance, Ships, Ship why, Records).
- `code/`: `spacetraders_theme.css` (daisyUI and Tailwind theme for the Phoenix app) and `heex_components.md` (function component specs).
- `Mission Control.dc.html`: the full prototype. `design_handoff_mission_control/`: the Claude Code handoff.
- `SKILL.md`: an Agent Skill wrapper.

## Intentional additions
All components come from the Mission Control prototype; the repo has no component library. DataBadge exists only to label sample data during design work.
