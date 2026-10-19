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
  alias SpaceTraders.MissionControl.{Channels, PlanHealth}

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

    {:ok, socket |> assign(refresh: nil, next_change: nil) |> recompute()}
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

    assign(socket, health: health, next_change: next_change)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:glance}>
      <div id="glance" class="grid gap-3 md:grid-cols-[400px_1fr] md:gap-5">
        <div class="space-y-3">
          <.health_card state={@health.state} reason={@health.reason} checks={@health.checks} />
        </div>
      </div>
    </Layouts.app>
    """
  end
end
