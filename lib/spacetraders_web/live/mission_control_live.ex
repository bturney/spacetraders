defmodule SpaceTradersWeb.MissionControlLive do
  @moduledoc """
  Glance: answers "is the Fleet succeeding and on plan?" at one look.

  It opens with Plan Health (`MissionControl.PlanHealth`), read from stored
  and in-memory facts; mounting and updating make no game request. Ship,
  Intent, allocation, Strategy and Earnings changes mark the summary dirty: it
  is re-read at most once per second, only after a change. One timer re-reads
  it at the earliest moment an "old" rule would flip, so silent staleness
  still shows. Nothing here asks the Operator to act.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Clock, Fleet, FleetGeneration}
  alias SpaceTraders.MissionControl.{Channels, Happenings, Motion, PlanHealth}

  @refresh_ms 1_000
  @flash_ms 4_500
  @not_earning_shown 2

  @impl true
  def mount(_params, _session, socket) do
    agent =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> agent
        _ -> nil
      end

    if connected?(socket) do
      Channels.subscribe_strategy()
      Channels.subscribe_allocation()
      Channels.subscribe_earnings()
      Fleet.subscribe_intent_changes()
      if agent, do: Fleet.subscribe_ship_state(agent.id)
    end

    {:ok,
     socket
     |> assign(agent: agent, refresh: nil, next_change: nil, flashes: %{}, last_sale: nil)
     |> recompute()}
  end

  @impl true
  def handle_info(:recompute, socket),
    do: {:noreply, socket |> assign(refresh: nil) |> recompute()}

  def handle_info(:next_change, socket), do: {:noreply, recompute(socket)}

  def handle_info({:unflash, symbol, record_id}, socket) do
    flashes =
      case socket.assigns.flashes do
        %{^symbol => {^record_id, _amount}} = flashes -> Map.delete(flashes, symbol)
        flashes -> flashes
      end

    {:noreply, assign(socket, flashes: flashes)}
  end

  # Every other message is a prompt that something changed: re-read once, shortly.
  def handle_info(_prompt, %{assigns: %{refresh: ref}} = socket) when ref != nil,
    do: {:noreply, socket}

  def handle_info(_prompt, socket),
    do: {:noreply, assign(socket, refresh: Process.send_after(self(), :recompute, @refresh_ms))}

  defp recompute(socket) do
    health = PlanHealth.read(socket.assigns.current_scope, Clock.utc_now())
    if socket.assigns.next_change, do: Process.cancel_timer(socket.assigns.next_change)

    next_change =
      case connected?(socket) && health.next_change_at do
        %DateTime{} = at ->
          delay = max(0, DateTime.diff(at, Clock.utc_now(), :millisecond)) + 1
          Process.send_after(self(), :next_change, delay)

        _ ->
          nil
      end

    socket
    |> assign(health: health, next_change: next_change)
    |> read_fleet()
  end

  defp read_fleet(%{assigns: %{agent: nil}} = socket),
    do: assign(socket, motion: nil, events: [])

  defp read_fleet(%{assigns: %{agent: agent}} = socket) do
    events = Happenings.read(agent)

    socket
    |> assign(motion: Motion.read(agent, Clock.utc_now()), events: events)
    |> announce_sales(events)
  end

  # The first read only notes the latest sale; later reads announce new ones.
  defp announce_sales(socket, events) do
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
    |> push_event("sold", %{amount: sale.amount, detail: "#{sale.ship} · #{sale.detail}"})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:glance}>
      <div id="glance" class="grid grid-cols-1 gap-3 md:grid-cols-[400px_1fr] md:gap-5">
        <div class="space-y-3">
          <.health_card state={@health.state} reason={@health.reason} checks={@health.checks} />
        </div>
        <div class="space-y-3">
          <.motion_card :if={@motion} motion={@motion} sold={sold(@flashes)} />
          <.happenings_feed events={@events} />
        </div>
        <.sold_toast_host id="sold-toast" />
      </div>
    </Layouts.app>
    """
  end

  defp sold(flashes), do: Map.new(flashes, fn {symbol, {_id, amount}} -> {symbol, amount} end)

  attr :motion, :map, required: true
  attr :sold, :map, required: true

  defp motion_card(assigns) do
    assigns =
      assign(assigns,
        total: length(assigns.motion.rows),
        shown: Enum.take(assigns.motion.not_earning, @not_earning_shown),
        more: max(0, length(assigns.motion.not_earning) - @not_earning_shown)
      )

    ~H"""
    <.card id="ships-in-motion">
      <.eyebrow>
        Ships in motion<:right>{@total}</:right>
      </.eyebrow>
      <p :if={@total == 0} id="motion-empty" class="mt-1.5 text-sm text-dim">No Ships yet.</p>
      <div :if={@motion.mode == :cards} id="motion-cards" class="mt-2 space-y-2">
        <.ship_card :for={row <- @motion.rows} row={row} sold={@sold[row.symbol]} />
      </div>
      <div :if={@motion.mode == :grid} id="motion-grid" class="mt-2">
        <.fleet_grid rows={@motion.rows} sold={@sold} counts={@motion.counts} />
        <div id="not-earning" class="mt-2.5 min-h-[calc(2*24px+16px)]">
          <.eyebrow>Not earning right now</.eyebrow>
          <ul class="mt-1">
            <li
              :for={row <- @shown}
              id={"not-earning-#{row.id}"}
              class="flex h-6 items-center gap-2 text-xs"
            >
              <.link navigate={"/ships/#{row.symbol}"} class="num w-[72px] flex-none">
                {row.symbol}
              </.link>
              <.status_chip status={chip_status(row.status.status)} small />
              <span class="min-w-0 flex-1 truncate text-muted">{row.status.phrase}</span>
            </li>
          </ul>
          <p :if={@more > 0} id="not-earning-more" class="text-xs text-dim">+{@more} more</p>
          <p :if={@shown == []} id="not-earning-none" class="text-xs text-dim">
            Every Ship is earning or waiting on purpose.
          </p>
        </div>
      </div>
    </.card>
    """
  end
end
