# Context-burden audit — #595

Findings only for [#595](https://github.com/bturney/spacetraders/issues/595)
(map [#591](https://github.com/bturney/spacetraders/issues/591)). No split is
decided here.

## Sources and method

- Revision: `origin/main` @ `5d98a50` (2026-10-05). Repo history starts
  2026-08-05, so "3 months" = whole history (873 commits).
- Size: `wc -l` on `lib/**/*.ex` and `test/**/*.exs`.
- Churn: `git log --since=3.months --format= --name-only | sort | uniq -c`,
  plus `--since=1.month` / `--since=2.weeks` per file and `--numstat`.
- Structure: `grep -n '^  defp\? '` per module; caller counts via
  `grep -rhoE 'Intents\.[a-z_?!]+' lib test`.
- Agent read cost: read-only query of the opencode session store
  (`~/.local/share/opencode/opencode.db`, `part` rows with `type: tool`), last
  14 days, 330 spacetraders sessions incl. subagents. "Reads" = `read` tool
  calls; "full" = no `offset`/`limit`. Chars are tool output size (~4
  chars/token).
- Retro: Claude Code session `19ab8367-a72a-4943-947c-5efbd2dc5851`
  (2026-10-05, `/retro` over 14 days of opencode history), suggestion 4.
  No retro notes exist in `docs/`, closed issues/PRs, or
  `~/.claude/projects/-home-ben-src-spacetraders/memory/` (empty).

## Retro finding (primary trigger)

> `lib/spacetraders/fleet/intents.ex` is 5,381 lines and was read 667 times
> (5.2M chars). It's also the top target of the 118 failed edits.
> Fix: add a ratchet to `scripts/verify` … fails on any `.ex` file over about
> 1,500 lines that isn't on an allowlist.

Re-measured below (643 reads / 5.06M chars; small delta = window drift).

## Hotspot table

| File | Lines | Commits 3mo / 1mo / 2wk | Reads 14d (full) | Read chars 14d | Edits (failed) |
|---|---:|---|---:|---:|---:|
| `lib/spacetraders/fleet/intents.ex` | 5,373 | 81 / 59 / 41 | 643 (11) | 5.06M (~1.27M tok) | 301 (19) |
| `lib/spacetraders/fleet_allocation.ex` | 1,906 | 27 / 25 / – | 261 (16) | 2.57M | 105 (8) |
| `lib/spacetraders/fleet.ex` | 1,091 | 222 / 38 / 13 | 248 (2) | 1.52M | 124 (9) |
| `lib/spacetraders/fleet_planning.ex` | 2,712 | 20 / 20 / – | 138 (11) | 1.46M | 95 (8) |
| `lib/spacetraders/fleet_execution.ex` | 1,083 | 16 / – / – | 131 (21) | 1.40M | – |
| `lib/spacetraders/evidence.ex` | 1,706 | 25 / 25 / – | 142 (8) | 1.21M | 16 (2) |
| `GLOSSARY.md` (was `CONTEXT.md`) | 35 KB | 41 / – / – | 151 (110) | 4.15M | – |
| `test/spacetraders/owned_intent_recovery_test.exs` | 3,364 | 16 / – / 16 | <60 | <0.43M | 43 (2) |
| `test/spacetraders/intelligence_acquisition_test.exs` | 2,483 | 13 / – / 13 | 60 (1) | 0.43M | 87 (3) |

`–` = not measured. Next tier by size (no hotspot signal): `mission_control.ex`
1,126, `fleet_construction.ex` 1,034, `api/operation_inventory.ex` 1,019
(generated-ish), `strategy_live.ex` 986.

Key pattern: agents rarely read big modules whole (11 of 643 `intents.ex`
reads). They grep, then page windows (~7.9K chars each), many times per
session. Cost is read *count* × window, driven by having to locate private
helpers scattered across one file. Edit failures track the same files: an
`old_string` that is not unique in 5K lines fails.

## 1. `fleet/intents.ex` — 5,373 lines, 45 public / 392 private fns

**Why read.** It is the single seam for Intent execution: commitment requests,
reconcile/advance, recorded-action dispatch, recovery, and every action
family's progress/complete/block logic. Any change to a Ship action family
(nav, cargo, delivery, refit, intelligence, resources, transfer) lands here.
External surface is small: `reconcile` (99 call sites), `request_commitment_*`
(~50), `current`, `advance`, `rearm_on_boot`, `execute_action`,
`transition_intent`, `history` cover nearly all callers (16 `lib` files).

**When it changes.** 59 commits in the last month, 41 in two weeks
(12.1K lines inserted / 6.8K deleted over history). The recent run is
family-by-family: "Unify refit / Market buy-sell / resource / scan-chart /
Contract-Construction delivery / two-Ship transfer / refuel-jump / navigation
recovery" — eight commits, each touching one family plus the shared recovery
core. That is the seam the code already wants.

**Natural seams** (approx. line spans; families interleave today):

| Cluster | ~Lines | Location (current) |
|---|---:|---|
| Public seam: stop/intervene, reconcile entry, boot rearm, current/history | 540 | 1–540 |
| Commitment request builders (`request_commitment_*`, params) | 450 | 541–990 |
| Core engine: advance/replace/terminalize, bind claim, transitions, `execute_action`, selected-action recovery, block/defer/infeasible/supersede | 1,350 | 991–1380, 2615–2770, 4264–5030, 5231–5300 |
| Navigation: nav, refuel, warp, jump, fuel preflight, arrival | 965 | 1505–1585, 3650–4264, 5033–5230, 5301–5373 |
| Market cargo / trade | 615 | 2307–2615, 2767–2930, 3214–3355 |
| Resources: extract, survey, refine, jettison | 410 | 1898–2307 |
| Intelligence: scan, chart | 310 | 1585–1898 |
| Delivery: Contract, Construction | 295 | 3355–3650 |
| Refit / module install | 285 | 2931–3214 |
| Transfer (two-Ship) | 125 | 1381–1505 |

Precedent: `Fleet.Intents.RecordedAction` (530) and `Fleet.Intents.Recovery`
(96) already split out under `lib/spacetraders/fleet/intents/`.

**Estimated read-cost reduction.** A family change today needs the family
code plus the core engine, located by grep across 5.4K lines. With one module
per family plus a core module: family (125–965) + core (~1,350) ≈ 1.5–2.3K
lines, a 55–70% cut in the file an agent must navigate; ~85–95% if the core
is stable enough to read by its `@doc`s only. Risk: families call many core
privates (`update_intent!`, `block_intents`, `complete_intents`,
`continue_after_reconciled_action`), so the core needs a deliberate internal
interface, not a mechanical cut.

## 2. `fleet_allocation.ex` — 1,906 lines, 34 public / 69 private

**Why read.** Portfolio selection, publication, replanning, Ship Claim
authority (`authorize_ship_execution`, `current_ship_claim`) and outcome
recording. Second-highest code read cost (261 reads, 2.57M chars) because
`intents.ex` calls claim/authority functions on every action path.

**Seams.** (a) Selection/ranking — pure: `select_portfolio`,
`build_portfolio`, `rank_plans`, `plan_rejections`, `compare_keys`
(~1239–1906, ~670 lines). (b) Publication/replan/unwind — Repo writes
(~163–455, 842–1116). (c) Ship Claim authority (`current_ship_claim`,
`ship_claim_binding`, `authorize_ship_execution`, ~693–842). (d) Outcomes
(`record_*_outcome`, `reconcile_completed_outcomes`, `realized_economics`).
Embedded structs `FleetCommitment`, `PortfolioCandidate` could move to their
own files. `fleet_allocation/neutral_wait.ex` (511) is the precedent.

**Reduction.** Intents-side work usually needs only (c) (~150 lines) — ~90%
less than the whole file. Selection work needs (a) alone (~35%).

## 3. `fleet_planning.ex` — 2,712 lines, 25 public / 126 private

**Why read.** Pure planner; one `plan_*` per objective family. Read when
adding or changing an objective (refit, acquisition, construction, contracts,
market, intelligence, resources).

**Seams.** Already organized by `plan_*` public functions; private helpers
follow their caller. Approx.: refit + ship acquisition 273–1073 (~800),
contracts 1073–1221 (~150), construction + transfer supply 1221–1980 (~760),
market/coverage demand 1980–2712 (~730), plus `CandidateContribution` struct
(24–60). One module per objective family under `fleet_planning/`.

**Reduction.** ~70–85% per change (one family of 150–800 lines vs 2,712).
Lower urgency: 20 commits/month, 138 reads.

## 4. `evidence.ex` — 1,706 lines, 55 public / 76 private

**Why read.** Observation Demands, authoritative evidence getters
(`get_ship`, `get_market`, …), recovery bindings/proofs. Read on every
recovery change (the "retained Evidence" unification run).

**Seams.** (a) Bindings/recovery proof (`*_binding`, `recovery_proof`,
`valid_recovery_source?`, `recovery_fresh?`, ~48–220, 1223–1546). (b)
Authoritative getters (`get_*`, ~219–720) — uniform shape, rarely read for
logic. (c) Demand lifecycle (`request/replace/withdraw/sync/fulfil_demands`,
~720–1222). [#561](https://github.com/bturney/spacetraders/issues/561)
already proposes deepening proof assembly — align any split with it.

**Reduction.** Recovery work reads (a) only (~500 lines): ~70%. Lowest edit
volume of the four (16 edits) — mostly a read burden.

## 5. `fleet.ex` — cooled churn hotspot, not a split candidate

Top of churn (222 commits / 3mo; 21K inserted, 19.5K deleted) because legacy
gameplay retirement (2026-09-23/24) rewrote and shrank it. Now 1,091 lines,
42 public fns, 13 commits in two weeks. 248 reads but only 2 full: agents
look up single read functions. Watch, don't split.
(`dashboard_live.ex`, 170 commits, is deleted.)

## 6. Oversized tests

- `owned_intent_recovery_test.exs` (3,364 lines, 73 tests, no `describe`):
  tests for intelligence, delivery, market, refuel/navigation and generic
  lifecycle interleave, each with family-local `defp` fixtures
  (`selected_delivery`, `market_selection`, `selected_intelligence`, …).
  Splits the same way as `intents.ex` (one file per family + shared fixtures
  module). Also wall-clock relevant for #591's suite baseline.
- `intelligence_acquisition_test.exs` (2,483 lines, 31 tests): 87 edits /
  3 failed in 14 days. One family; split by scenario only if it keeps growing.
- `recorded_family_interruption_test.exs` (1,128) and `fleet_refit_test.exs`
  (1,143) are already family-shaped.

## 7. Adjacent: glossary read cost

`GLOSSARY.md` (35 KB) is the #2 read cost overall: 151 reads, 110 full,
4.15M chars. Not domain code, but the same burden; the retro proposed
"grep the term" guidance in `docs/agents/domain.md`. Belongs with #591's
instruction-surface work.

## Options for the spec (not decisions)

1. Split `intents.ex` by action family behind a core-engine module; the
   family-by-family commit history is the seam evidence.
2. Extract Ship Claim authority from `fleet_allocation.ex`.
3. Per-objective modules for `fleet_planning.ex`; recovery-proof module
   for `evidence.ex` (coordinate with #561).
4. Size ratchet in the gate (retro: ~1,500-line cap, allowlist that only
   shrinks) so new hotspots cannot grow back.
5. Mirror the `intents.ex` split in `owned_intent_recovery_test.exs`.
