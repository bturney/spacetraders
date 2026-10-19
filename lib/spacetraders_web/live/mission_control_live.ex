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
  alias SpaceTraders.MissionControl.{Channels, Credits, PlanHealth}

  @refresh_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Channels.subscribe_strategy()
      Channels.subscribe_allocation()
      Channels.subscribe_earnings()
      Fleet.subscribe_intent_changes()

      with {:ok, %{state: :current, agent: agent}} <-
             FleetGeneration.current_fleet(socket.assigns.current_scope) do
        Fleet.subscribe_ship_state(agent.id)
      end
    end

    {:ok, socket |> assign(refresh: nil, next_change: nil, credits: nil, credits_flash: nil)
     |> recompute()}
  end

  @impl true
  def handle_info(:recompute, socket),
    do: {:noreply, socket |> assign(refresh: nil) |> recompute()}

  def handle_info(:next_change, socket), do: {:noreply, recompute(socket)}

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

    socket |> assign(health: health, next_change: next_change) |> read_credits()
  end

  # A balance that rose since the last read flashes its gain until the next read.
  defp read_credits(socket) do
    credits = Credits.read(socket.assigns.current_scope, Clock.utc_now())
    before = socket.assigns.credits && socket.assigns.credits.balance
    now = credits && credits.balance
    flash = if before && now && now > before, do: now - before

    assign(socket, credits: credits, credits_flash: flash)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:glance}>
      <div id="glance" class="grid gap-3 md:grid-cols-[400px_1fr] md:gap-5">
        <div class="space-y-3">
          <.health_card state={@health.state} reason={@health.reason} checks={@health.checks} />
          <.credits_card credits={@credits} flash={@credits_flash} />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :credits, :map, default: nil
  attr :flash, :integer, default: nil

  # Balance (counting up), growth over the Generation and the 6 h Net Earnings.
  defp credits_card(assigns) do
    assigns = assign(assigns, :c, assigns.credits || %{})

    ~H"""
    <.card id="credits-card">
      <.eyebrow>Credits</.eyebrow>
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
