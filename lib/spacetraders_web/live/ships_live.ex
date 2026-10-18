defmodule SpaceTradersWeb.ShipsLive do
  @moduledoc """
  Every current Ship by name, read from stored Ship state.

  Mounting and updating make no game request. Each stored Ship change arrives
  as one message and re-renders one stream row; route markers and countdowns
  move in the browser. One timer re-renders rows at the earliest moment a
  silent Ship turns overdue.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Clock, Fleet, FleetGeneration}
  alias SpaceTraders.MissionControl.ShipRow

  @impl true
  def mount(_params, _session, socket) do
    agent =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> agent
        _ -> nil
      end

    if agent && connected?(socket), do: Fleet.subscribe_ship_state(agent.id)

    now = Clock.utc_now()

    rows =
      if agent, do: Enum.map(Fleet.current_ships(agent.id), &ShipRow.build(&1, now)), else: []

    socket =
      socket
      |> assign(agent: agent, count: length(rows), timer: nil)
      |> assign(pending: pending(rows))
      |> stream(:ships, rows)
      |> schedule_overdue()

    {:ok, socket}
  end

  @impl true
  def handle_info({:ship_state, ship}, socket) do
    row = ShipRow.build(ship, Clock.utc_now())

    socket
    |> update(:pending, &track(&1, row))
    |> stream_insert(:ships, row)
    |> schedule_overdue()
    |> then(&{:noreply, &1})
  end

  def handle_info(:overdue, socket) do
    now = Clock.utc_now()
    {due, pending} = Map.split_with(socket.assigns.pending, fn {_id, at} -> due?(at, now) end)

    rows =
      socket.assigns.agent.id
      |> Fleet.current_ships(Map.keys(due))
      |> Enum.map(&ShipRow.build(&1, now))

    socket
    |> assign(pending: Enum.reduce(rows, pending, &track(&2, &1)), timer: nil)
    |> then(fn socket -> Enum.reduce(rows, socket, &stream_insert(&2, :ships, &1)) end)
    |> schedule_overdue()
    |> then(&{:noreply, &1})
  end

  # Rows not yet overdue, by the moment they become so.
  defp pending(rows), do: Enum.reduce(rows, %{}, &track(&2, &1))

  defp track(pending, %{overdue?: false, overdue_at: %DateTime{} = at, id: id}),
    do: Map.put(pending, id, at)

  defp track(pending, %{id: id}), do: Map.delete(pending, id)

  defp due?(at, now), do: DateTime.compare(at, now) != :gt

  defp schedule_overdue(socket) do
    if socket.assigns.timer, do: Process.cancel_timer(socket.assigns.timer)

    timer =
      case socket.assigns.pending |> Map.values() |> Enum.min(DateTime, fn -> nil end) do
        nil ->
          nil

        at ->
          delay = max(0, DateTime.diff(at, Clock.utc_now(), :millisecond))
          Process.send_after(self(), :overdue, delay)
      end

    assign(socket, timer: timer)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:ships}>
      <.eyebrow>
        Ships<:right>{@count}</:right>
      </.eyebrow>

      <p :if={!@agent} id="ships-empty" class="text-dim">No current Fleet.</p>

      <div id="ships" phx-update="stream" class="space-y-2">
        <.card :for={{dom_id, row} <- @streams.ships} id={dom_id}>
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <.link navigate={~p"/ships/#{row.symbol}"} class="font-medium">{row.symbol}</.link>
              <div class="text-xs text-dim">
                {row.location}<span :if={row.overdue?} class="text-warning"> · as of {clock(
                  row.observed_at
                )}</span>
              </div>
            </div>
            <.countdown
              id={"countdown-#{row.id}"}
              until={row.arrive_at}
              caption={row.in_transit? && "to arrival"}
              size={18}
            />
          </div>
          <div class="mt-2">
            <.route_bar
              id={"route-#{row.id}"}
              from={row.from}
              to={row.to}
              at={row.at}
              depart_at={row.depart_at}
              arrive_at={row.arrive_at}
              size={:sm}
            />
          </div>
          <div class="num mt-1 flex justify-between gap-3 text-xs text-dim">
            <span>Fuel {fuel(row.fuel)}</span>
            <span>{cargo(row.cargo)}</span>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp clock(_), do: "—"

  defp fuel({_current, 0}), do: "not needed"
  defp fuel({current, capacity}), do: "#{format_int(current)}/#{format_int(capacity)}"

  defp cargo([]), do: "No cargo"
  defp cargo(items), do: Enum.map_join(items, ", ", fn {good, units} -> "#{units} #{good}" end)
end
