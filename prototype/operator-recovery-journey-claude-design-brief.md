# Brief: Mission Control for a self-playing space trading fleet

## What this is

SpaceTraders is an online game: Ships fly between waypoints in a star system, buy goods cheap, sell them dear, and grow a pile of credits. My fleet plays itself — an autonomous engine picks every trade. I only watch.

Mission Control is the screen I watch it on. Today it fails: in 60 seconds I can't tell whether it's going well, what the Ships are doing, why, or what happens next. It's full of engine jargon ("commitment portfolio", "Decision Episode 4920", "Expected value 609.1989143581985").

Design a clickable prototype of a better one.

## Principles (non-negotiable)

1. **It's a game first.** Watching the fleet play must be fun and easy to follow — for someone who has never played. Prefer visual forms (route bars, countdowns, charts, motion) over text.
2. **Game vocabulary, not engine internals.** "Hauling 20 Ammunition F47 → E45", not "Commitment 8483 pursuing objective 0".
3. **Nothing needs me.** No "needs attention", no action prompts, no alerts asking me to intervene. A stuck Ship is a tuning problem to analyse later, not a call to act.
4. **Honest numbers.** Estimates are labelled as estimates. Unknown is never shown as zero; a headline unknown says why and when it will be known. Hide unknowns that don't change understanding.
5. **Fast and calm.** Live updates must not make the page jump while I'm reading.

## Journeys to cover (one connected experience, not separate mockups)

1. **Glance** (phone shows all of this without scrolling):
   - Plan health: green "on plan", yellow "small setback, recoverable", red "off plan, real blocker", plus a distinct grey "can't tell right now" — each with a one-line reason.
   - Credits now, a growth line over the whole game, and the earning rate (credits/hour).
   - Ships in motion.
2. **Ship list** — ordered by name; must work for 2 Ships and for 100+ Ships. Each row at a glance: what it's doing (plain verb phrase), where from → where to, time to arrival, cargo, expected profit, and a status: trading / busy but not earning / waiting on purpose (with countdown) / stuck.
3. **Ship → Why** — a plain sentence: what it chose, over what alternatives, and why; then how its recent trades went, expected vs actual.
4. **Deeper analysis in Grafana, then back** — a link from the Ship or the glance that opens a Grafana dashboard answering a stated question (show the Grafana page as a mock), with a way back.
5. **Records** — a few fun stats: best single trade, most valuable good, trades completed.

Events should feel like events: a sale lands (credits tick up, profit shown).

## Situations to show (switchable)

| Situation | Real or sample | What's true |
|---|---|---|
| Healthy trading | Real | 2 Ships. HARDBARGAIN-1 trades; HARDBARGAIN-2 is a small probe that flies market to market checking prices. A trade every ~3–4 min. Credits 172k → 2.87M over 5 days. |
| Busy but not earning | Real (12 Oct, 23:00–23:55) | 14 trades in an hour netted only +2,848 (usual ~13–15k/h): one Lab Instruments trade C41 → A4 expected +860 and lost 8,000. Several buys skipped because the price rose before the Ship arrived (e.g. planned 2,985, actual 3,154). |
| Waiting on purpose | Sample | Every known trade would lose money after fuel, so the Ship waits at C41; next look in ~5 min. This is healthy. |
| Stuck, recovering | Sample | Ship at G49 without enough fuel to leave; retries itself every 90 s; stuck 12 min. |
| Old information | Sample | Prices are 44 min old (trusted up to 30); the probe is 2 markets behind and catches up in ~9 min. Health: "can't tell right now". |

Also show a 120-Ship sample fleet (mostly trading, a few waiting, ~8 busy-not-earning, ~4 stuck, ~10 probes).

## Real examples to use

- **Trade in progress:** bought 20 Ammunition at F47 for 1,846 each; sells at E45 for ~1,887; expected +820. Chosen over Fertilizers G49 → E46 (+560) and Hydrocarbon C41 → G49 (+520). The E45 price is 28 min old. Estimates leave out fuel.
- **Recent sale:** 20 Electronics F48 → C41: paid 59,700, sold 61,040, profit +1,340 (expected +980).
- **Best trade this game:** Lab Instruments C41 → A4, +43,620 (11 Oct).
- **Most valuable good:** Ship Parts, 469k profit. Then Medicine 390k, Fabrics 380k, Electronics 303k.
- **Totals:** 1,277 trades, 3.13M trading profit before fuel; fuel cost 397k; 626 buys skipped because prices rose.
- **Grafana question with a real answer — "Do old prices cost us money?"** Not much: trades on 20–30 min old prices beat their estimate by +80 on average vs +120 on fresh prices; 31 of the 48 big misses (over 500) used fresh prices. The worst misses are one route: Lab Instruments C41 → A4 lost 8,000 twice, expecting +860.
- **Grafana question for players — "Where do our credits come from?"** Trading earned 3.13M before costs; fuel took 397k (13%); no contract, charting or ship-buying income or costs yet.

Waypoints are short codes (F47, E45, C41…). Ships are named HARDBARGAIN-1, -2, …

## Out of scope

An interactive star map. Manual gameplay controls. Notifications. Settings.

## Deliverable

A clickable prototype — desktop and phone — that I can click through: glance → ship list → one Ship and its why → Grafana mock → back. Include a control to switch situations and 2 vs 120 Ships. Clearly mark sample data as sample.
