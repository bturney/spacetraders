defmodule SpaceTradersWeb.MissionControlLive do
  @moduledoc """
  Glance: answers "is the Fleet succeeding and on plan?" at one look.

  One recompute (`MissionControl.Glance`) reads Plan Health, credits, Ships in
  motion and the feed from stored and in-memory facts; mounting and updating
  make no game request. A stored Ship change re-renders that Ship's card or
  cell at once from its last known status. Every change also marks the
  summary dirty: it is re-read at most once per second, only after a change,
  and only rows that changed are pushed. One timer re-reads it at the
  earliest moment an "old" rule would flip, so silent staleness still shows.
  Nothing here asks the Operator to act.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Clock, Fleet}
  alias SpaceTraders.MissionControl.{Channels, Glance, Motion, ShipRow}
  alias SpaceTradersWeb.{FleetLive, GrafanaLink, PlanHealthText}

  @flash_ms 4_500
  @not_earning_shown 1

  @impl true
  def mount(_params, _session, socket) do
    agent = FleetLive.current_agent(socket.assigns.current_scope)

    if connected?(socket) do
      Channels.subscribe_strategy()
      FleetLive.subscribe(agent)
    end

    {:ok,
     socket
     |> assign(
       agent: agent,
       events: [],
       refresh: nil,
       next_change: nil,
       flashes: %{},
       last_sale: nil,
       credits: nil,
       credits_flash: nil,
       motion: nil,
       rows: %{}
     )
     |> stream_configure(:cards, dom_id: &"ship-card-#{&1.id}")
     |> stream_configure(:cells, dom_id: &"fleet-grid-cell-#{&1.id}")
     |> stream(:cards, [])
     |> stream(:cells, [])
     |> recompute()}
  end

  @impl true
  def handle_info(:recompute, socket),
    do: {:noreply, socket |> assign(refresh: nil) |> recompute()}

  def handle_info(:next_change, socket), do: {:noreply, recompute(socket)}

  def handle_info({:unflash, symbol, record_id}, socket) do
    case socket.assigns.flashes do
      %{^symbol => {^record_id, _amount}} = flashes ->
        socket = assign(socket, flashes: Map.delete(flashes, symbol))
        {:noreply, refresh_row(socket, symbol)}

      _ ->
        {:noreply, socket}
    end
  end

  # One stored Ship change: its own row now, the summary within a second.
  def handle_info({:ship_state, ship}, socket) do
    socket =
      case Map.fetch(socket.assigns.rows, ship.id) do
        {:ok, old} -> put_rows(socket, [ShipRow.build(ship, old.status, Clock.utc_now())])
        :error -> socket
      end

    {:noreply, FleetLive.mark_dirty(socket, :recompute)}
  end

  # Every other message is a prompt that something changed: re-read once, shortly.
  def handle_info(_prompt, socket), do: {:noreply, FleetLive.mark_dirty(socket, :recompute)}

  defp recompute(socket) do
    now = Clock.utc_now()
    glance = Glance.read(socket.assigns.current_scope, now)

    socket
    |> assign(health: PlanHealthText.word(glance.health))
    |> schedule_next_change(glance.health.next_change_at, now)
    |> put_credits(glance.credits)
    |> put_motion(glance.motion)
    |> announce_sales(glance.events)
  end

  defp schedule_next_change(socket, at, now) do
    if socket.assigns.next_change, do: Process.cancel_timer(socket.assigns.next_change)

    next_change =
      case connected?(socket) && at do
        %DateTime{} = at ->
          Process.send_after(
            self(),
            :next_change,
            max(0, DateTime.diff(at, now, :millisecond)) + 1
          )

        _ ->
          nil
      end

    assign(socket, next_change: next_change)
  end

  # A balance that rose since the last read flashes its gain until the next read.
  defp put_credits(socket, credits) do
    before = socket.assigns.credits && socket.assigns.credits.balance
    now = credits && credits.balance
    flash = if before && now && now > before, do: now - before

    assign(socket, credits: credits, credits_flash: flash)
  end

  defp put_motion(socket, nil),
    do: socket |> assign(motion: nil, rows: %{}) |> stream(:cards, [], reset: true)

  # A new mode or a new set of Ships re-lists the rows; otherwise only
  # changed rows are pushed.
  defp put_motion(socket, motion) do
    old = socket.assigns.motion

    if old && old.mode == motion.mode &&
         Map.keys(socket.assigns.rows) |> Enum.sort() ==
           motion.rows |> Enum.map(& &1.id) |> Enum.sort() do
      socket |> assign(motion: Map.delete(motion, :rows)) |> put_rows(motion.rows)
    else
      rows = Enum.map(motion.rows, &sold(socket, &1))
      {shown, hidden} = if motion.mode == :cards, do: {:cards, :cells}, else: {:cells, :cards}

      socket
      |> assign(motion: Map.delete(motion, :rows), rows: Map.new(rows, &{&1.id, &1}))
      |> stream(shown, rows, reset: true)
      |> stream(hidden, [], reset: true)
    end
  end

  # Re-renders the given rows that changed; counts and Not earning follow.
  defp put_rows(%{assigns: %{motion: nil}} = socket, _rows), do: socket

  defp put_rows(socket, rows) do
    stream = if socket.assigns.motion.mode == :cards, do: :cards, else: :cells

    {socket, all} =
      Enum.reduce(rows, {socket, socket.assigns.rows}, fn row, {socket, all} ->
        row = sold(socket, row)

        if all[row.id] == row,
          do: {socket, all},
          else: {stream_insert(socket, stream, row), Map.put(all, row.id, row)}
      end)

    summary =
      all |> Map.values() |> Enum.sort_by(&Fleet.name_order(&1.symbol)) |> Motion.summary()

    assign(socket, rows: all, motion: Map.delete(summary, :rows))
  end

  defp refresh_row(socket, symbol) do
    case Enum.find(Map.values(socket.assigns.rows), &(&1.symbol == symbol)) do
      nil -> socket
      row -> put_rows(socket, [row])
    end
  end

  defp sold(socket, row) do
    case Map.fetch(socket.assigns.flashes, row.symbol) do
      {:ok, {_id, amount}} -> Map.put(row, :sold, amount)
      :error -> Map.put(row, :sold, nil)
    end
  end

  # The first read only notes the latest sale; later reads announce new ones.
  defp announce_sales(socket, events) do
    socket = assign(socket, events: events)
    sales = for %{kind: :sale} = event <- events, do: event
    newest = sales |> Enum.map(& &1.record_id) |> Enum.max(fn -> 0 end)

    case socket.assigns.last_sale do
      nil ->
        assign(socket, last_sale: newest)

      last ->
        fresh = sales |> Enum.filter(&(&1.record_id > last)) |> Enum.sort_by(& &1.record_id)
        socket = assign(socket, last_sale: max(last, newest))
        if connected?(socket), do: Enum.reduce(fresh, socket, &announce_sale/2), else: socket
    end
  end

  defp announce_sale(sale, socket) do
    Process.send_after(self(), {:unflash, sale.ship, sale.record_id}, @flash_ms)

    socket
    |> update(:flashes, &Map.put(&1, sale.ship, {sale.record_id, sale.amount}))
    |> refresh_row(sale.ship)
    |> push_event("sold", %{amount: sale.amount, detail: "#{sale.ship} · #{sale.detail}"})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:glance}>
      <div id="glance" class="grid grid-cols-1 gap-2 md:grid-cols-[400px_1fr] md:gap-5">
        <div class="space-y-2 md:space-y-3">
          <.health_card state={@health.state} reason={@health.reason} checks={@health.checks} />
          <.credits_card credits={@credits} flash={@credits_flash} />
        </div>
        <div class="space-y-2 md:space-y-3">
          <.motion_card
            :if={@motion}
            motion={@motion}
            total={map_size(@rows)}
            cards={@streams.cards}
            cells={@streams.cells}
          />
          <.happenings_feed events={@events} />
        </div>
        <.sold_toast_host id="sold-toast" />
      </div>
    </Layouts.app>
    """
  end

  attr :motion, :map, required: true
  attr :total, :integer, required: true
  attr :cards, :any, required: true
  attr :cells, :any, required: true

  defp motion_card(assigns) do
    assigns =
      assign(assigns,
        shown: Enum.take(assigns.motion.not_earning, @not_earning_shown),
        more: max(0, length(assigns.motion.not_earning) - @not_earning_shown),
        grafana: GrafanaLink.url(:fleet, from: "now-6h", to: :now)
      )

    ~H"""
    <.card id="ships-in-motion">
      <.eyebrow>
        Ships in motion<:right>
          <a id="motion-grafana" href={@grafana} target="_blank" rel="noopener">{@total} ↗</a>
        </:right>
      </.eyebrow>
      <p :if={@total == 0} id="motion-empty" class="mt-1.5 text-sm text-dim">No Ships yet.</p>
      <div
        :if={@motion.mode == :cards}
        id="motion-cards"
        phx-update="stream"
        class="mt-2 space-y-2"
      >
        <.ship_card :for={{_dom_id, row} <- @cards} row={row} sold={row.sold} />
      </div>
      <div :if={@motion.mode == :grid} id="motion-grid" class="mt-1.5">
        <.fleet_grid rows={@cells} counts={@motion.counts} />
        <div id="not-earning" class="mt-2 min-h-[calc(24px+14px)]">
          <.eyebrow>
            Not earning right now<:right>
              <span :if={@more > 0} id="not-earning-more">+{@more} more</span>
            </:right>
          </.eyebrow>
          <ul class="mt-1">
            <li
              :for={row <- @shown}
              id={"not-earning-#{row.id}"}
              class="flex h-6 items-center gap-2 text-xs"
            >
              <.link navigate={"/ships/#{row.symbol}"} class="num w-[72px] flex-none">
                {row.symbol}
              </.link>
              <.status_chip status={chip_status(row.status.kind)} small />
              <span class="min-w-0 flex-1 truncate text-muted">{row.status.phrase}</span>
            </li>
          </ul>
          <p :if={@shown == []} id="not-earning-none" class="text-xs text-dim">
            Every Ship is earning or waiting on purpose.
          </p>
        </div>
      </div>
    </.card>
    """
  end

  attr :credits, :map, default: nil
  attr :flash, :integer, default: nil

  # Balance (counting up), growth over the Generation and the 6 h Net Earnings.
  defp credits_card(assigns) do
    assigns =
      assign(assigns,
        c: assigns.credits || %{},
        grafana: assigns.credits && GrafanaLink.url(:money, from: "now-6h", to: :now)
      )

    ~H"""
    <.card id="credits-card">
      <.eyebrow>
        Credits<:right>
          <a :if={@grafana} id="credits-grafana" href={@grafana} target="_blank" rel="noopener">
            Money ↗
          </a>
        </:right>
      </.eyebrow>
      <div class="mt-1.5">
        <.credits_ticker
          :if={@c[:balance]}
          id="credits-balance"
          value={@c.balance}
          flash={@flash}
          size={36}
        />
        <span :if={!@c[:balance]} class="num text-4xl font-semibold text-dim">—</span>
      </div>
      <div class="mt-2 flex items-end justify-between gap-3">
        <div id="credits-growth" class="num text-sm text-muted">
          <span class={@c[:growth] && @c.growth < 0 && "text-error"}>
            {format_signed(@c[:growth])}
          </span>
          <span class="text-dim"> this Generation</span>
        </div>
        <.growth_line id="credits-growth-line" series={@c[:series] || []} />
      </div>
      <div class="mt-3 border-t border-line pt-2.5">
        <div class="flex items-baseline justify-between gap-3">
          <span id="credits-rate-window" class="text-xs text-dim">
            Net Earnings · {rate_window(@c[:since])}
          </span>
          <span id="credits-rate" class="num text-xl font-semibold">
            {format_signed(@c[:net])}
          </span>
        </div>
        <p :if={@c[:per_hour]} class="num mt-0.5 text-right text-xs text-dim">
          {format_signed(@c.per_hour)} / h after fuel
        </p>
      </div>
    </.card>
    """
  end

  defp rate_window(%DateTime{} = since), do: "since #{Calendar.strftime(since, "%H:%M")}"
  defp rate_window(_full), do: "last 6 h"

  attr :id, :string, required: true
  attr :series, :list, required: true

  # The balance over the Generation as one line; flat and empty when under two points.
  defp growth_line(assigns) do
    values = Enum.map(assigns.series, & &1.credits)
    {low, high} = Enum.min_max(values, fn -> {0, 0} end)
    span = max(high - low, 1)
    last = max(length(values) - 1, 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {v, i} ->
        "#{Float.round(i * 100 / last, 1)},#{Float.round(28 - (v - low) * 26 / span, 1)}"
      end)

    assigns = assign(assigns, points: points, enough: length(values) >= 2)

    ~H"""
    <svg
      id={@id}
      viewBox="0 0 100 30"
      preserveAspectRatio="none"
      class="h-8 w-28 flex-none"
      aria-hidden="true"
    >
      <polyline
        :if={@enough}
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        vector-effect="non-scaling-stroke"
        class="text-trading"
      />
    </svg>
    """
  end
end
