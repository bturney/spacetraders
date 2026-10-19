defmodule SpaceTradersWeb.MissionControlComponents do
  @moduledoc """
  Mission Control design system components (#749): Card, Eyebrow, StatusChip,
  DataBadge, Money, HealthCard, RouteBar, Countdown, SoldToast, CreditsTicker.

  Copy rules: game vocabulary, the fixed status wording, and honest numbers
  (unknown is "—", never 0). Every number is mono with tabular numerals so live
  updates never shift layout. Nothing here asks the Operator to act.
  """
  use Phoenix.Component

  @minus "−"

  @tones %{
    trading: "bg-trading/9 border-trading/35",
    busy: "bg-busy/9 border-busy/35",
    waiting: "bg-waiting/9 border-waiting/35",
    stuck: "bg-stuck/9 border-stuck/35",
    scouting: "bg-scouting/9 border-scouting/35",
    unknown: "bg-unknown/9 border-unknown/35",
    on: "bg-success/9 border-success/35",
    setback: "bg-warning/9 border-warning/35",
    off: "bg-error/9 border-error/35"
  }

  @status %{
    trading: {"Trading", "bg-trading/16 text-trading", "bg-trading"},
    busy: {"Busy, not earning", "bg-busy/16 text-busy", "bg-busy"},
    waiting: {"Waiting on purpose", "bg-waiting/16 text-waiting", "bg-waiting"},
    stuck: {"Stuck", "bg-stuck/16 text-stuck", "bg-stuck"},
    scouting: {"Scouting prices", "bg-scouting/16 text-scouting", "bg-scouting"}
  }

  @fill %{
    trading: {"bg-trading/55", "bg-trading", "shadow-[0_0_8px_var(--color-trading)]"},
    busy: {"bg-busy/55", "bg-busy", "shadow-[0_0_8px_var(--color-busy)]"},
    waiting: {"bg-waiting/55", "bg-waiting", "shadow-[0_0_8px_var(--color-waiting)]"},
    stuck: {"bg-stuck/55", "bg-stuck", "shadow-[0_0_8px_var(--color-stuck)]"},
    scouting: {"bg-scouting/55", "bg-scouting", "shadow-[0_0_8px_var(--color-scouting)]"}
  }

  @doc "Statuses a Ship can show, in the fixed vocabulary."
  def statuses, do: Map.keys(@status)

  # -- number formatting -------------------------------------------------

  @doc "Integer with thousands separators: `1340` -> `\"1,340\"`; negatives use U+2212."
  def format_int(nil), do: "—"

  def format_int(value) when is_number(value) do
    n = round(value)
    digits = n |> abs() |> Integer.to_string() |> group_digits()
    if n < 0, do: @minus <> digits, else: digits
  end

  defp group_digits(digits) do
    digits
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  @doc "Signed credits: always a sign, U+2212 for loss, nil is an em dash."
  def format_signed(nil), do: "—"

  def format_signed(value) when is_number(value) do
    n = round(value)
    if n < 0, do: format_int(n), else: "+" <> format_int(n)
  end

  @doc "Seconds as `m:ss`; nil is an em dash. Past the moment clamps to 0:00."
  def format_clock(nil), do: "—"

  def format_clock(seconds) when is_number(seconds) do
    s = max(0, floor(seconds))
    "#{div(s, 60)}:#{s |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  # -- core -------------------------------------------------------------

  attr :tone, :atom, default: nil, values: [nil | Map.keys(@tones)]
  attr :inner, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "Surface for grouped content. A tone tints the card; inner cards sit inside cards."
  def card(assigns) do
    assigns = assign(assigns, :tone_class, Map.get(@tones, assigns.tone))

    ~H"""
    <div
      class={[
        "border px-3.5 py-[11px] md:px-[18px] md:py-4",
        @inner && "rounded-[10px] border-line bg-base-300",
        !@inner && "rounded-box",
        !@inner && !@tone_class && "border-line bg-base-200",
        @tone_class && ["transition-colors duration-[600ms]", @tone_class],
        @class
      ]}
      data-tone={@tone}
      {@rest}
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :rest, :global
  slot :inner_block, required: true
  slot :right

  @doc "Mono uppercase label; the optional right slot is plain text."
  def eyebrow(assigns) do
    ~H"""
    <div
      class={[
        "flex justify-between gap-2 font-mono text-[10px] tracking-[.14em] uppercase text-dim",
        @class
      ]}
      {@rest}
    >
      <span>{render_slot(@inner_block)}</span>
      <span :if={@right != []} class="tracking-[.04em] normal-case">{render_slot(@right)}</span>
    </div>
    """
  end

  attr :status, :atom, required: true, values: Map.keys(@status)
  attr :small, :boolean, default: false
  attr :label, :string, default: nil, doc: "overrides the fixed label, e.g. a verb phrase"

  def status_chip(assigns) do
    {label, chip, dot} = Map.fetch!(@status, assigns.status)
    assigns = assign(assigns, label_text: assigns.label || label, chip: chip, dot: dot)

    ~H"""
    <span
      class={[
        "inline-flex items-center gap-1.5 rounded-full font-medium whitespace-nowrap",
        @chip,
        @small && "px-[7px] py-0.5 text-[11px]",
        !@small && "px-[9px] py-[3px] text-xs"
      ]}
      data-status={@status}
    >
      <span class={["size-1.5 rounded-full", @dot]}></span>{@label_text}
    </span>
    """
  end

  attr :sample, :boolean, default: false
  attr :short, :boolean, default: false

  @doc "Labels data as REAL or SAMPLE. Drop once all data is real."
  def data_badge(assigns) do
    ~H"""
    <span class={[
      "rounded-[5px] border px-[7px] py-1 font-mono text-[10px] tracking-[.12em] whitespace-nowrap",
      @sample && "border-warning text-warning",
      !@sample && "border-success text-success"
    ]}>{if @sample, do: "SAMPLE", else: "REAL"}{if !@short, do: " DATA"}</span>
    """
  end

  attr :value, :integer, default: nil, doc: "credits; nil renders an em dash, never 0"
  attr :est, :boolean, default: false, doc: "adds an est. suffix"
  attr :stale, :boolean, default: false, doc: "based on old prices: adds a ~ prefix"
  attr :class, :any, default: nil

  def money(assigns) do
    ~H"""
    <span :if={is_nil(@value)} class={["num text-[13px] text-dim", @class]}>—</span>
    <span
      :if={!is_nil(@value)}
      class={[
        "num whitespace-nowrap text-[13px]",
        (@value < 0 && "text-error") || "text-base-content",
        @class
      ]}
    >{if @stale, do: "~"}{format_signed(@value)}<span :if={@est} class="text-[10px] text-dim"> est.</span></span>
    """
  end

  # -- fleet --------------------------------------------------------------

  @health %{
    on: {"On plan", "text-success", "bg-success shadow-[0_0_12px_var(--color-success)]"},
    setback:
      {"Small setback, recoverable", "text-warning",
       "bg-warning shadow-[0_0_12px_var(--color-warning)]"},
    off:
      {"Off plan, real blocker", "text-error", "bg-error shadow-[0_0_12px_var(--color-error)]"},
    unknown:
      {"Can't tell right now", "text-unknown", "border-[1.5px] border-dashed border-unknown"}
  }

  @check_dot %{
    ok: "bg-success",
    amber: "bg-warning",
    red: "bg-error",
    unknown: "border border-dashed border-unknown"
  }

  attr :id, :string, default: "plan-health"
  attr :state, :atom, required: true, values: Map.keys(@health)
  attr :reason, :string, required: true

  attr :checks, :list,
    default: [],
    doc: "`%{name, label, state, detail}`, state :ok/:amber/:red/:unknown"

  @doc """
  Plan Health: one of four states, one plain reason line and the four checks.
  Can't tell is grey and hollow, never green. Nothing here asks to act.
  """
  def health_card(assigns) do
    {label, text, dot} = Map.fetch!(@health, assigns.state)
    assigns = assign(assigns, label: label, text: text, dot: dot, check_dot: @check_dot)

    ~H"""
    <.card id={@id} tone={@state} data-state={@state}>
      <div class="flex items-center gap-2.5">
        <span class={["size-3.5 flex-none rounded-full", @dot]}></span>
        <span class={["flex-1 text-lg font-semibold", @text]}>{@label}</span>
        <.eyebrow>Plan health</.eyebrow>
      </div>
      <p id={"#{@id}-reason"} class="mt-1.5 text-sm leading-snug text-muted">{@reason}</p>
      <ul class="mt-3 grid grid-cols-2 gap-x-3 gap-y-1.5">
        <li
          :for={check <- @checks}
          id={"#{@id}-check-#{check.name}"}
          data-state={check.state}
          class="flex min-w-0 items-center gap-1.5 text-xs"
          title={check.detail}
        >
          <span class={["size-2 flex-none rounded-full", @check_dot[check.state]]}></span>
          <span class="truncate">{check.label}</span>
        </li>
      </ul>
    </.card>
    """
  end

  # -- live ---------------------------------------------------------------

  @doc "Share of the trip flown, 0.0..1.0, from departure and arrival times."
  def progress(%DateTime{} = depart_at, %DateTime{} = arrive_at, %DateTime{} = now) do
    total = DateTime.diff(arrive_at, depart_at, :millisecond)

    if total <= 0 do
      1.0
    else
      (DateTime.diff(now, depart_at, :millisecond) / total) |> max(0.0) |> min(1.0)
    end
  end

  def progress(_depart_at, _arrive_at, _now), do: 0.0

  attr :id, :string, required: true
  attr :from, :string, default: nil
  attr :to, :string, default: nil
  attr :at, :string, default: nil, doc: "waypoint code when parked; shows a draining bar"
  attr :depart_at, :any, default: nil
  attr :arrive_at, :any, default: nil
  attr :now, :any, default: nil
  attr :status, :atom, default: :trading, values: Map.keys(@fill)
  attr :size, :atom, default: :md, values: [:sm, :md, :lg]

  @doc "Origin, destination and a marker. Rendered once; the RouteBar hook moves it from the timestamps."
  def route_bar(assigns) do
    now = assigns.now || DateTime.utc_now()
    {bar, marker, glow} = Map.fetch!(@fill, assigns.status)

    {track, mark, code} =
      Map.fetch!(%{sm: {5, 8, 11}, md: {8, 12, 12}, lg: {10, 16, 13}}, assigns.size)

    assigns =
      assign(assigns,
        pct: Float.round(progress(assigns.depart_at, assigns.arrive_at, now) * 100, 2),
        bar: bar,
        marker: marker,
        glow: glow,
        track_px: track,
        mark_px: mark,
        code_px: code,
        depart_ms: ms(assigns.depart_at),
        arrive_ms: ms(assigns.arrive_at)
      )

    ~H"""
    <div
      id={@id}
      phx-hook=".RouteBar"
      data-depart={@depart_ms}
      data-arrive={@arrive_ms}
      data-parked={@at && "true"}
      class="flex items-center gap-2"
    >
      <span class="num min-w-[30px] text-muted" style={"font-size:#{@code_px}px"}>{@at || @from}</span>
      <div class="relative flex-1" style={"height:#{@mark_px}px"}>
        <div
          class="absolute inset-x-0 overflow-hidden rounded-full bg-track"
          style={"top:#{(@mark_px - @track_px) / 2}px;height:#{@track_px}px"}
        >
          <div
            data-bar
            class={["h-full transition-[width] duration-[250ms] ease-linear", @bar]}
            style={"width:#{(@at && 100 - @pct) || @pct}%"}
          >
          </div>
        </div>
        <div
          :if={!@at}
          data-marker
          class={[
            "absolute top-0 rotate-45 scale-[.8] transition-[left] duration-[250ms] ease-linear",
            @marker,
            @glow
          ]}
          style={"width:#{@mark_px}px;height:#{@mark_px}px;left:calc(#{@pct}% - #{@mark_px / 2}px)"}
        >
        </div>
      </div>
      <span
        :if={!@at}
        class="num min-w-[30px] text-right text-muted"
        style={"font-size:#{@code_px}px"}
      >
        {@to}
      </span>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RouteBar">
      export default {
        mounted() { this.start() },
        updated() { this.start() },
        destroyed() { clearInterval(this.timer) },
        start() {
          clearInterval(this.timer)
          const d = Number(this.el.dataset.depart), a = Number(this.el.dataset.arrive)
          if (!d || !a || a <= d) return
          const parked = this.el.dataset.parked === "true"
          const tick = () => {
            const p = Math.min(1, Math.max(0, (Date.now() - d) / (a - d)))
            const bar = this.el.querySelector("[data-bar]")
            const marker = this.el.querySelector("[data-marker]")
            if (bar) bar.style.width = (parked ? (1 - p) : p) * 100 + "%"
            if (marker) {
              const half = parseFloat(marker.style.width) / 2
              marker.style.left = `calc(${p * 100}% - ${half}px)`
            }
            if (p >= 1) clearInterval(this.timer)
          }
          tick()
          this.timer = setInterval(tick, 250)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :until, :any, default: nil, doc: "DateTime of the expected moment; nil renders an em dash"
  attr :now, :any, default: nil
  attr :caption, :string, default: nil
  attr :size, :integer, default: 24

  @doc "Counts down to `until`, ticking each second in the Countdown hook. Fixed width, tabular."
  def countdown(assigns) do
    now = assigns.now || DateTime.utc_now()

    seconds =
      case assigns.until do
        %DateTime{} = until -> DateTime.diff(until, now, :second)
        _ -> nil
      end

    assigns =
      assign(assigns,
        text: format_clock(seconds),
        until_ms: ms(assigns.until),
        min_w: round(assigns.size * 2.6),
        caption_px: max(10, round(assigns.size * 0.42))
      )

    ~H"""
    <div class="text-right" style={"min-width:#{@min_w}px"}>
      <div
        id={@id}
        phx-hook=".Countdown"
        data-until={@until_ms}
        class="num font-medium leading-[1.1] text-base-content"
        style={"font-size:#{@size}px"}
      >
        {@text}
      </div>
      <div :if={@caption} class="text-dim" style={"font-size:#{@caption_px}px"}>{@caption}</div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".Countdown">
      export default {
        mounted() { this.start() },
        updated() { this.start() },
        destroyed() { clearInterval(this.timer) },
        start() {
          clearInterval(this.timer)
          const until = Number(this.el.dataset.until)
          if (!until) { this.el.textContent = "—"; return }
          const tick = () => {
            const s = Math.max(0, Math.floor((until - Date.now()) / 1000))
            this.el.textContent = Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0")
            if (s === 0) clearInterval(this.timer)
          }
          tick()
          this.timer = setInterval(tick, 1000)
        }
      }
    </script>
    """
  end

  attr :amount, :integer, required: true
  attr :detail, :string, default: nil
  attr :more, :integer, default: nil, doc: "sales folded into this pop-up"
  attr :visible, :boolean, default: true

  @doc "One SOLD pop-up pill. Positioned absolutely by its host so it never shifts layout."
  def sold_toast(assigns) do
    ~H"""
    <div
      class="sold-toast inline-flex max-w-full items-center gap-2.5 rounded-full border border-line bg-base-300 px-3.5 py-[9px] shadow-[0_8px_24px_oklch(0_0_0/.4)]"
      data-visible={to_string(@visible)}
    >
      <span class={[
        "rounded-[4px] px-1.5 py-0.5 font-mono text-[10px] font-semibold tracking-[.12em] text-page",
        (@amount < 0 && "bg-error") || "bg-success"
      ]}>SOLD</span>
      <span class={["num text-base", (@amount < 0 && "text-error") || "text-success"]}>
        {format_signed(@amount)}
      </span>
      <span class="truncate text-[13px] text-muted">{@detail}{if @more, do: " · +#{@more} more"}</span>
    </div>
    """
  end

  attr :id, :string, required: true

  @doc """
  Host for SOLD pop-ups. Push `push_event(socket, "sold", %{amount: 120, detail: "20 Fabrics · F47"})`;
  the hook shows at most one pop-up per 2.6 s and folds the rest into "+N more".
  """
  def sold_toast_host(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".SoldToastHost"
      phx-update="ignore"
      class="pointer-events-none fixed inset-x-0 bottom-20 z-30 flex justify-center px-4 md:bottom-6"
    >
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SoldToastHost">
      export default {
        mounted() {
          this.queue = []
          this.last = 0
          this.handleEvent("sold", (sale) => {
            this.queue.push(sale)
            this.drain()
          })
        },
        destroyed() { clearTimeout(this.wait); clearTimeout(this.hide) },
        drain() {
          if (this.wait || this.queue.length === 0) return
          const gap = 2600 - (Date.now() - this.last)
          if (gap > 0) {
            this.wait = setTimeout(() => { this.wait = null; this.drain() }, gap)
            return
          }
          const batch = this.queue.splice(0)
          const top = batch.reduce((a, b) => (Math.abs(b.amount) > Math.abs(a.amount) ? b : a))
          this.show(top, batch.length - 1)
          this.last = Date.now()
        },
        show(sale, more) {
          const sign = sale.amount < 0 ? "−" : "+"
          const color = sale.amount < 0 ? "error" : "success"
          const el = document.createElement("div")
          el.className = "sold-toast inline-flex max-w-full items-center gap-2.5 rounded-full border border-line bg-base-300 px-3.5 py-[9px] shadow-[0_8px_24px_oklch(0_0_0/.4)]"
          el.dataset.visible = "false"
          const tag = document.createElement("span")
          tag.className = `rounded-[4px] px-1.5 py-0.5 font-mono text-[10px] font-semibold tracking-[.12em] text-page bg-${color}`
          tag.textContent = "SOLD"
          const amt = document.createElement("span")
          amt.className = `num text-base text-${color}`
          amt.textContent = sign + Math.abs(Math.round(sale.amount)).toLocaleString("en-US")
          const detail = document.createElement("span")
          detail.className = "truncate text-[13px] text-muted"
          detail.textContent = (sale.detail || "") + (more > 0 ? ` · +${more} more` : "")
          el.append(tag, amt, detail)
          this.el.replaceChildren(el)
          requestAnimationFrame(() => { el.dataset.visible = "true" })
          clearTimeout(this.hide)
          this.hide = setTimeout(() => { el.dataset.visible = "false" }, 2400)
        }
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :value, :integer, required: true
  attr :flash, :integer, default: nil, doc: "latest gain, shown beside the balance"
  attr :size, :integer, default: 44

  @doc "Credits balance. The hook eases the shown number upward by 18% of the gap per 200 ms."
  def credits_ticker(assigns) do
    ~H"""
    <div class="relative inline-block">
      <span
        id={@id}
        phx-hook=".CreditsTicker"
        data-value={@value}
        class={[
          "num font-semibold transition-colors duration-[600ms]",
          (@flash && "text-success") || "text-base-content"
        ]}
        style={"font-size:#{@size}px"}
      >{format_int(@value)}</span>
      <span
        :if={@flash}
        class="num absolute top-1 left-full ml-2.5 whitespace-nowrap text-success"
        style={"font-size:#{round(@size * 0.36)}px"}
      >{format_signed(@flash)}</span>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CreditsTicker">
      export default {
        mounted() { this.shown = Number(this.el.dataset.value); this.sync() },
        updated() { this.sync() },
        destroyed() { clearInterval(this.timer) },
        sync() {
          clearInterval(this.timer)
          const target = Number(this.el.dataset.value)
          const paint = () => {
            const n = Math.round(this.shown)
            const text = Math.abs(n).toLocaleString("en-US")
            this.el.textContent = n < 0 ? "−" + text : text
          }
          if (target < this.shown) { this.shown = target; paint(); return }
          paint()
          this.timer = setInterval(() => {
            const gap = target - this.shown
            this.shown = Math.abs(gap) < 1 ? target : this.shown + gap * 0.18
            paint()
            if (this.shown === target) clearInterval(this.timer)
          }, 200)
        }
      }
    </script>
    """
  end

  # -- fleet (#771) -------------------------------------------------------

  @cell %{
    trading: {"bg-trading/18", "bg-trading/70"},
    busy: {"bg-busy/18", "bg-busy/70"},
    waiting: {"bg-waiting/18", "bg-waiting/70"},
    stuck: {"bg-stuck/18", "bg-stuck/70"},
    scouting: {"bg-scouting/18", "bg-scouting/70"}
  }

  @doc "The status chip atom of a `MissionControl.ShipStatus` status."
  def chip_status(:busy_not_earning), do: :busy
  def chip_status(status), do: status

  attr :row, :map, required: true, doc: "a `MissionControl.ShipRow`"
  attr :sold, :integer, default: nil, doc: "Net Earnings of a sale landed in the last 4.5 s"

  @doc """
  One Ship as a route card (small Fleets). A sale tints the card and shows
  "+X sold just now" in the countdown's own box, so nothing moves.
  """
  def ship_card(assigns) do
    chip = chip_status(assigns.row.status.status)

    assigns =
      assign(assigns,
        chip: chip,
        tone: sale_tone(assigns.sold),
        count_until: count_until(assigns.row),
        count_caption: count_caption(assigns.row)
      )

    ~H"""
    <.card inner id={"ship-card-#{@row.id}"} tone={@tone} data-sold={@sold && "true"}>
      <div class="flex items-start gap-2">
        <div class="flex min-w-0 flex-1 flex-col gap-1">
          <div class="flex items-center gap-2">
            <.link navigate={"/ships/#{@row.symbol}"} class="num text-xs">{@row.symbol}</.link>
            <.status_chip status={@chip} small />
          </div>
          <span class="truncate text-sm text-muted">{@row.status.phrase}</span>
        </div>
        <div class="grid min-w-[68px] text-right">
          <div class={["col-start-1 row-start-1", @sold && "invisible"]}>
            <.countdown
              id={"ship-card-countdown-#{@row.id}"}
              until={@count_until}
              caption={@count_caption}
              size={20}
            />
          </div>
          <div :if={@sold} class="col-start-1 row-start-1">
            <div class={["num text-2xl", (@sold < 0 && "text-error") || "text-success"]}>
              {format_signed(@sold)}
            </div>
            <div class="text-[10px] text-dim">sold just now</div>
          </div>
        </div>
      </div>
      <div class="mt-2">
        <.route_bar
          id={"ship-card-route-#{@row.id}"}
          from={@row.from}
          to={@row.to}
          at={@row.at}
          depart_at={@row.depart_at}
          arrive_at={@row.arrive_at}
          status={@chip}
          size={:sm}
        />
      </div>
    </.card>
    """
  end

  attr :id, :string, default: "fleet-grid"
  attr :rows, :list, required: true, doc: "`MissionControl.ShipRow`s, in name order"
  attr :sold, :map, default: %{}, doc: "Ship symbol => Net Earnings of a sale in the last 4.5 s"
  attr :counts, :map, required: true, doc: "ShipStatus status => number of Ships"
  attr :columns, :integer, default: 40

  @doc """
  One cell per Ship (large Fleets): a fill that rises with its trip, tinted by
  status, a green outline for a sale in the last 4.5 s, and the status counts.
  Cells have fixed size, so live updates never shift the layout.
  """
  def fleet_grid(assigns) do
    assigns = assign(assigns, cells: @cell, chips: @status)

    ~H"""
    <div>
      <div
        id={@id}
        phx-hook=".FleetGrid"
        class="grid gap-[3px]"
        style={"grid-template-columns:repeat(#{@columns},minmax(0,1fr))"}
      >
        <.link
          :for={row <- @rows}
          id={"#{@id}-cell-#{row.id}"}
          navigate={"/ships/#{row.symbol}"}
          title={row.symbol}
          data-status={row.status.status}
          data-depart={ms(row.depart_at)}
          data-arrive={ms(row.arrive_at)}
          data-sold={@sold[row.symbol] && "true"}
          class={[
            "relative aspect-square overflow-hidden rounded-[2px] outline-offset-[-1.5px]",
            elem(@cells[chip_status(row.status.status)], 0),
            @sold[row.symbol] && "outline outline-[1.5px] outline-success"
          ]}
        >
          <span
            data-fill
            class={[
              "absolute inset-x-0 bottom-0 transition-[height] duration-[250ms] ease-linear",
              elem(@cells[chip_status(row.status.status)], 1)
            ]}
            style={"height:#{fill(row)}%"}
          ></span>
        </.link>
      </div>
      <div class="mt-2 flex flex-wrap gap-x-3.5 gap-y-1 text-xs text-muted">
        <span
          :for={{status, n} <- @counts}
          :if={n > 0}
          id={"#{@id}-count-#{status}"}
          class="flex items-center gap-1.5"
        >
          <span class={["size-2 rounded-[2px]", elem(@chips[chip_status(status)], 2)]}></span>
          {elem(@chips[chip_status(status)], 0)} <span class="num">{n}</span>
        </span>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".FleetGrid">
      export default {
        mounted() { this.start() },
        updated() { this.start() },
        destroyed() { clearInterval(this.timer) },
        start() {
          clearInterval(this.timer)
          const tick = () => {
            const now = Date.now()
            this.el.querySelectorAll("[data-arrive]").forEach((cell) => {
              const d = Number(cell.dataset.depart), a = Number(cell.dataset.arrive)
              const fill = cell.querySelector("[data-fill]")
              if (!d || !a || a <= d || !fill) return
              fill.style.height = Math.min(1, Math.max(0, (now - d) / (a - d))) * 100 + "%"
            })
          }
          tick()
          this.timer = setInterval(tick, 1000)
        }
      }
    </script>
    """
  end

  @kind_dot %{
    sale: "bg-success",
    best: "bg-success",
    skipped_buy: "bg-busy",
    joined: "bg-scouting",
    stuck: "bg-stuck",
    recovered: "bg-trading"
  }

  attr :id, :string, default: "happenings"
  attr :events, :list, required: true, doc: "`MissionControl.Happenings` events"

  @doc """
  "Just happened": the last 8 events, newest first. The list keeps the height of
  eight rows, so the first events arriving move nothing below it.
  """
  def happenings_feed(assigns) do
    assigns = assign(assigns, dots: @kind_dot)

    ~H"""
    <.card id={@id}>
      <.eyebrow>Just happened</.eyebrow>
      <ul class="mt-1 min-h-[calc(8*20px)]">
        <li
          :for={event <- @events}
          id={"#{@id}-#{event.id}"}
          data-kind={event.kind}
          class="flex h-5 items-center gap-2 text-xs"
        >
          <span class="num w-[38px] flex-none text-dim">{Calendar.strftime(event.at, "%H:%M")}</span>
          <span class={["size-1.5 flex-none rounded-full", @dots[event.kind]]}></span>
          <span class="min-w-0 flex-1 truncate">{event.text}</span>
          <span
            :if={event.amount}
            class={[
              "num w-[58px] flex-none text-right",
              (event.amount < 0 && "text-error") || "text-success"
            ]}
          >
            {format_signed(event.amount)}
          </span>
        </li>
      </ul>
      <p :if={@events == []} id={"#{@id}-empty"} class="text-sm text-dim">
        Nothing yet. Sales, skipped buys, new Ships and stuck Ships appear here.
      </p>
    </.card>
    """
  end

  defp sale_tone(nil), do: nil
  defp sale_tone(amount) when amount < 0, do: :stuck
  defp sale_tone(_amount), do: :on

  defp fill(%{status: %{status: :stuck}}), do: 100

  defp fill(%{depart_at: %DateTime{} = depart, arrive_at: %DateTime{} = arrive}),
    do: Float.round(progress(depart, arrive, DateTime.utc_now()) * 100, 1)

  defp fill(_row), do: 0

  defp count_until(%{in_transit?: true, arrive_at: at}), do: at
  defp count_until(%{status: %{next_attempt_at: %DateTime{} = at}}), do: at
  defp count_until(%{status: %{next_check_at: %DateTime{} = at}}), do: at
  defp count_until(_row), do: nil

  defp count_caption(%{in_transit?: true}), do: "to arrival"
  defp count_caption(%{status: %{next_attempt_at: %DateTime{}}}), do: "next attempt"
  defp count_caption(%{status: %{next_check_at: %DateTime{}}}), do: "next check"
  defp count_caption(_row), do: nil

  defp ms(%DateTime{} = dt), do: DateTime.to_unix(dt, :millisecond)
  defp ms(_), do: nil
end
