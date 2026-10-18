defmodule SpaceTradersWeb.ShipsLive do
  @moduledoc """
  Every current Ship by name with its status, read from stored state.

  Mounting and updating make no game request. Each stored Ship change arrives
  as one message and re-renders one stream row; route markers and countdowns
  move in the browser. Intent, allocation and Earnings changes mark statuses
  dirty: they are re-read at most once per second, only after a change, and
  only rows whose status changed are pushed. One timer re-renders rows at the
  earliest moment a silent Ship turns overdue. Status chips filter the list.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.{Clock, Fleet, FleetGeneration}
  alias SpaceTraders.MissionControl.{Channels, ShipRow, ShipStatus}

  @refresh_ms 1_000
  @chips %{
    trading: :trading,
    scouting: :scouting,
    waiting: :waiting,
    stuck: :stuck,
    busy_not_earning: :busy
  }

  @impl true
  def mount(_params, _session, socket) do
    agent =
      case FleetGeneration.current_fleet(socket.assigns.current_scope) do
        {:ok, %{state: :current, agent: agent}} -> agent
        _ -> nil
      end

    if agent && connected?(socket) do
      Fleet.subscribe_ship_state(agent.id)
      Fleet.subscribe_intent_changes()
      Channels.subscribe_earnings()
      Channels.subscribe_allocation()
    end

    socket
    |> assign(agent: agent, filter: nil, timer: nil, refresh: nil, statuses: %{}, pending: %{})
    |> load()
    |> then(&{:ok, &1})
  end

  @impl true
  def handle_event("filter", %{"status" => status}, socket) do
    filter = Enum.find(ShipStatus.statuses(), &(Atom.to_string(&1) == status))
    {:noreply, socket |> assign(filter: filter) |> load()}
  end

  @impl true
  def handle_info({:ship_state, ship}, socket) do
    now = Clock.utc_now()
    status = ShipStatus.for_ships(socket.assigns.agent, [ship], now) |> Map.fetch!(ship.id)

    socket
    |> put_rows([ShipRow.build(ship, status, now)])
    |> schedule_overdue()
    |> then(&{:noreply, &1})
  end

  def handle_info(:overdue, socket) do
    now = Clock.utc_now()
    {due, pending} = Map.split_with(socket.assigns.pending, fn {_id, at} -> due?(at, now) end)

    rows =
      socket.assigns.agent.id
      |> Fleet.current_ships(Map.keys(due))
      |> Enum.map(&ShipRow.build(&1, Map.get(socket.assigns.statuses, &1.id, %{}), now))

    socket
    |> assign(pending: pending, timer: nil)
    |> put_rows(rows)
    |> schedule_overdue()
    |> then(&{:noreply, &1})
  end

  def handle_info(:refresh_statuses, socket) do
    now = Clock.utc_now()
    ships = Fleet.current_ships(socket.assigns.agent.id)
    statuses = ShipStatus.for_ships(socket.assigns.agent, ships, now)

    rows =
      for ship <- ships, statuses[ship.id] != socket.assigns.statuses[ship.id] do
        ShipRow.build(ship, statuses[ship.id], now)
      end

    socket
    |> assign(refresh: nil)
    |> put_rows(rows)
    |> schedule_overdue()
    |> then(&{:noreply, &1})
  end

  # Intent, allocation and Earnings prompts: re-read statuses once, shortly.
  def handle_info(_prompt, %{assigns: %{agent: nil}} = socket), do: {:noreply, socket}

  def handle_info(_prompt, %{assigns: %{refresh: ref}} = socket) when ref != nil,
    do: {:noreply, socket}

  def handle_info(_prompt, socket),
    do:
      {:noreply,
       assign(socket, refresh: Process.send_after(self(), :refresh_statuses, @refresh_ms))}

  defp load(%{assigns: %{agent: nil}} = socket),
    do: socket |> assign(counts: counts(%{})) |> stream(:ships, [], reset: true)

  defp load(socket) do
    now = Clock.utc_now()
    ships = Fleet.current_ships(socket.assigns.agent.id)
    statuses = ShipStatus.for_ships(socket.assigns.agent, ships, now)
    rows = Enum.map(ships, &ShipRow.build(&1, statuses[&1.id], now))

    socket
    |> assign(statuses: statuses, counts: counts(statuses), pending: pending(rows))
    |> stream(:ships, Enum.filter(rows, &shown?(socket, &1)), reset: true)
    |> schedule_overdue()
  end

  # Changed rows replace their own; a row entering or leaving the filtered
  # list re-reads it so the order by name holds.
  defp put_rows(socket, rows) do
    statuses = Enum.reduce(rows, socket.assigns.statuses, &Map.put(&2, &1.id, &1.status))

    moved? =
      socket.assigns.filter &&
        Enum.any?(rows, fn row ->
          old = socket.assigns.statuses[row.id]
          (old && old.status) != row.status.status
        end)

    socket = assign(socket, statuses: statuses, counts: counts(statuses))

    if moved? do
      load(socket)
    else
      socket
      |> update(:pending, fn pending -> Enum.reduce(rows, pending, &track(&2, &1)) end)
      |> then(fn socket ->
        rows
        |> Enum.filter(&shown?(socket, &1))
        |> Enum.reduce(socket, &stream_insert(&2, :ships, &1))
      end)
    end
  end

  defp shown?(%{assigns: %{filter: nil}}, _row), do: true
  defp shown?(%{assigns: %{filter: filter}}, row), do: row.status.status == filter

  defp counts(statuses) do
    base = Map.new(ShipStatus.statuses(), &{&1, 0})
    Enum.reduce(statuses, base, fn {_id, %{status: s}}, acc -> Map.update!(acc, s, &(&1 + 1)) end)
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
    assigns = assign(assigns, total: assigns.counts |> Map.values() |> Enum.sum())

    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide active={:ships}>
      <.eyebrow>
        Ships<:right>{@total}</:right>
      </.eyebrow>

      <p :if={!@agent} id="ships-empty" class="text-dim">No current Fleet.</p>

      <div id="status-filters" class="my-2 flex flex-wrap gap-1.5">
        <button
          id="status-filter-all"
          type="button"
          phx-click="filter"
          phx-value-status="all"
          class={["rounded-full px-[9px] py-[3px] text-xs", !@filter && "bg-base-300"]}
          aria-pressed={to_string(is_nil(@filter))}
        >
          All <span class="num">{@total}</span>
        </button>
        <button
          :for={status <- ShipStatus.statuses()}
          id={"status-filter-#{status}"}
          type="button"
          phx-click="filter"
          phx-value-status={status}
          class={["rounded-full", @filter == status && "ring-1 ring-base-content/40"]}
          aria-pressed={to_string(@filter == status)}
        >
          <.status_chip status={chip(status)} small />
          <span class="num text-xs">{@counts[status]}</span>
        </button>
      </div>

      <div id="ships" phx-update="stream" class="space-y-2">
        <.card :for={{dom_id, row} <- @streams.ships} id={dom_id}>
          <div class="flex items-center justify-between gap-3">
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <.link navigate={~p"/ships/#{row.symbol}"} class="font-medium">{row.symbol}</.link>
                <.status_chip status={chip(row.status.status)} small />
              </div>
              <div class="text-xs">{row.status.phrase}{retry(row.status)}{estimate(row.status)}</div>
              <div class="text-xs text-dim">
                {row.location}<span :if={row.overdue?} class="text-warning"> · as of {clock(
                  row.observed_at
                )}</span>
              </div>
            </div>
            <.countdown
              id={"countdown-#{row.id}"}
              until={until(row)}
              caption={caption(row)}
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
              status={chip(row.status.status)}
              size={:sm}
            />
          </div>
          <div class="num mt-1 flex justify-between gap-3 text-xs text-dim">
            <span>Fuel {fuel(row.fuel)}</span>
            <span>{rate(row.status.credits_per_hour)}</span>
            <span>{cargo(row.cargo)}</span>
          </div>
        </.card>
      </div>
    </Layouts.app>
    """
  end

  defp chip(status), do: Map.fetch!(@chips, status)

  defp until(%{in_transit?: true, arrive_at: at}), do: at
  defp until(%{status: %{next_attempt_at: %DateTime{} = at}}), do: at
  defp until(%{status: %{next_check_at: %DateTime{} = at}}), do: at
  defp until(_row), do: nil

  defp caption(%{in_transit?: true}), do: "to arrival"
  defp caption(%{status: %{next_attempt_at: %DateTime{}}}), do: "next attempt"
  defp caption(%{status: %{next_check_at: %DateTime{}}}), do: "next check"
  defp caption(_row), do: nil

  defp retry(%{status: :stuck, retries: retries}) when is_integer(retries),
    do: " · retry #{retries}"

  defp retry(_status), do: nil

  defp estimate(%{estimate: estimate}) when is_integer(estimate),
    do: " · est. #{format_signed(estimate)}"

  defp estimate(_status), do: nil

  defp rate(nil), do: "— /h"
  defp rate(credits), do: "#{format_int(credits)}/h"

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")
  defp clock(_), do: "—"

  defp fuel({_current, 0}), do: "not needed"
  defp fuel({current, capacity}), do: "#{format_int(current)}/#{format_int(capacity)}"

  defp cargo([]), do: "No cargo"
  defp cargo(items), do: Enum.map_join(items, ", ", fn {good, units} -> "#{units} #{good}" end)
end
