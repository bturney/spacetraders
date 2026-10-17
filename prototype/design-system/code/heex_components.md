# HEEx component specs
Put these in `lib/spacetraders_web/components/mission_control_components.ex` (`use Phoenix.Component`). Each mirrors a React component in `/components`; visuals are defined there and in `code/spacetraders_theme.css`.

| Function | Attrs | Notes |
|---|---|---|
| `card/1` | `tone` (atom, opt), `inner` (bool), `class`, slot `inner_block` | `rounded-box border border-line bg-base-200 px-3.5 py-[11px]`; tone → `bg-{tone}/9 border-{tone}/35 transition-colors duration-[600ms]` |
| `eyebrow/1` | slot `inner_block`, slot `right` | `font-mono text-[10px] tracking-[.14em] uppercase text-dim` |
| `status_chip/1` | `status` :trading \| :busy \| :waiting \| :stuck \| :scouting, `small` | labels: Trading, Busy, not earning, Waiting on purpose, Stuck, Scouting prices |
| `data_badge/1` | `sample` (bool), `short` | REAL DATA green / SAMPLE DATA yellow outline. Drop once all data is real. |
| `money/1` | `value` (integer \| nil), `est`, `stale` | nil → "—" (never 0); stale → "~" prefix; est → " est." suffix; U+2212 minus |
| `route_bar/1` | `from`, `to`, `at`, `depart_at`, `arrive_at`, `status`, `size` | Render server-side once; `phx-hook="RouteBar"` moves marker client-side from timestamps (.25s linear) |
| `countdown/1` | `until` (DateTime \| nil), `caption` | `phx-hook="Countdown"` ticks 1s; fixed width, `tabular-nums`; nil → "—" |
| `health_card/1` | `state` :on \| :setback \| :off \| :unknown, `reason` | unknown dot is hollow dashed, no glow |
| `ship_row/1` | `ship`, `compact`, `sold` | grid areas per README; sold → tint + "+X sold" for 4.5s (JS.transition or hook) |
| `ship_card/1` | `ship`, `sold` | used when fleet ≤ 6 |
| `fleet_grid/1` | `ships`, `columns` (20 desktop / 24 phone) | one `<.link patch>` cell per Ship |
| `compare_bars/1` | `options` [%{label, value, chosen}] | |
| `dumbbell/1` | `label`, `expected`, `actual`, `note` | |
| `growth_line/1` | `points` | inline SVG path computed in Elixir |
| `sold_toast/1` | `amount`, `detail`, `more` | push via `push_event("sold", …)`; client batches ≤1 per 2.6s |

## Live-update rules
- Push fleet changes over PubSub; never re-render every second. Countdown and RouteBar hooks interpolate from `depart_at`/`arrive_at`.
- Use `phx-update="stream"` for the Ship list (100+ rows) keyed by ship symbol; sort by name with natural order.
- Credits count-up runs in a hook (18% of the gap per 200ms), so no layout shift.
