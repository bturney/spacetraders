defmodule SpaceTradersWeb.DashboardLive do
  @moduledoc """
  The fleet command panel dashboard.

  Mission-led layout: a contract hero placeholder, then per-agent sections with
  an overview card (live credits, headquarters, faction) and a fleet card grid
  (location, fuel, cargo, cooldown, docked/orbiting state). A thin consumer —
  every read goes through the `SpaceTraders.Agent` and `SpaceTraders.Fleet`
  contexts; there is no game logic here.

  Live data is pulled from the game API at mount time: the server is the source
  of truth and the local DB rows are a cache (ADR 0005). A per-agent fetch
  failure renders as a readable message instead of taking the dashboard down.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.Agent
  alias SpaceTraders.Fleet

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <%= if @operator do %>
        <div class="space-y-8">
          <div class="flex items-center justify-between">
            <div>
              <.header>
                Fleet command
                <:subtitle>
                  {@operator.email} — agents, credits and ships at a glance.
                </:subtitle>
              </.header>
            </div>
            <.link navigate={~p"/agents/new"} class="btn btn-primary">Mint an agent</.link>
          </div>

          <.contract_hero />

          <div :if={@overviews == []} class="alert alert-outline">
            You haven't minted any agents yet.
            <.link navigate={~p"/agents/new"} class="font-semibold underline">
              Mint your first agent
            </.link>
            .
          </div>

          <.agent_section :for={overview <- @overviews} overview={overview} />
        </div>
      <% else %>
        <div class="mx-auto max-w-lg py-16 text-center">
          <h1 class="text-4xl font-bold tracking-tight">SpaceTraders dashboard</h1>
          <p class="mt-4 text-lg opacity-80">
            Drive your fleet and missions from the browser. Log in or register to get started.
          </p>
          <div class="mt-10 flex justify-center gap-4">
            <.link href={~p"/operators/log-in"} class="btn btn-primary">Log in</.link>
            <.link href={~p"/operators/register"} class="btn btn-soft">Register</.link>
          </div>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    case socket.assigns.current_scope do
      nil -> mount_anonymous(socket)
      %{operator: operator} -> mount_operator(socket, operator)
    end
  end

  defp mount_anonymous(socket) do
    if Agent.has_operators?() do
      {:ok, assign(socket, :operator, nil)}
    else
      {:ok, redirect(socket, to: ~p"/setup")}
    end
  end

  defp mount_operator(socket, operator) do
    agents = Agent.list_agents(operator)

    for %{id: agent_id} <- agents do
      Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet:#{agent_id}")
    end

    overviews =
      agents
      |> Enum.map(fn agent ->
        %{agent: agent, overview: Agent.agent_overview(agent), ships: Fleet.list_ships(agent)}
      end)

    {:ok, assign(socket, operator: operator, overviews: overviews)}
  end

  @impl true
  def handle_event("navigate", %{"symbol" => ship_symbol, "waypoint_symbol" => waypoint}, socket) do
    waypoint = String.trim(waypoint || "")

    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- validate_waypoint(waypoint) do
      case Fleet.navigate_ship(agent, ship_symbol, waypoint) do
        {:ok, %{nav: %{route: %{destination: %{symbol: destination}}}}} ->
          socket = refresh_agent_fleet(socket, agent.id)
          {:noreply, put_flash(socket, :info, "#{ship_symbol} is in transit to #{destination}.")}

        {:ok, _result} ->
          socket = refresh_agent_fleet(socket, agent.id)
          {:noreply, put_flash(socket, :info, "#{ship_symbol} is in transit.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, live_error(reason))}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_info({:ship_updated, agent_id, _ship_symbol}, socket) do
    {:noreply, refresh_agent_fleet(socket, agent_id)}
  end

  defp agent_for_ship(socket, ship_symbol) do
    Enum.find_value(
      socket.assigns.overviews,
      {:error, "That ship is not in this agent's fleet."},
      fn overview ->
        case overview.ships do
          {:ok, ships} ->
            if Enum.any?(ships, &(&1.symbol == ship_symbol)) do
              {:ok, overview.agent}
            end

          _error ->
            nil
        end
      end
    )
  end

  defp validate_waypoint(""), do: {:error, "Enter a target waypoint."}
  defp validate_waypoint(_waypoint), do: :ok

  defp refresh_agent_fleet(socket, agent_id) do
    overviews =
      Enum.map(socket.assigns.overviews, fn overview ->
        if overview.agent.id == agent_id do
          %{overview | ships: Fleet.list_ships(overview.agent)}
        else
          overview
        end
      end)

    assign(socket, :overviews, overviews)
  end

  ## Components

  defp contract_hero(assigns) do
    ~H"""
    <div class="card border border-primary/30 bg-base-200 p-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="text-xs uppercase tracking-wider opacity-60">Active mission</p>
          <h2 class="mt-1 text-xl font-bold">No active mission</h2>
          <p class="mt-1 text-sm opacity-70">
            The contract hero lands with the contract lifecycle milestone and will surface
            your current mission, its deliverables and deadline at a glance.
          </p>
        </div>
        <span class="badge badge-outline">Missions</span>
      </div>
    </div>
    """
  end

  attr :overview, :map, required: true

  defp agent_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.agent_overview_card agent={@overview.agent} live={@overview.overview} />
      <.fleet_grid agent={@overview.agent} ships={@overview.ships} />
    </section>
    """
  end

  attr :agent, :map, required: true
  attr :live, :any, required: true

  defp agent_overview_card(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4 sm:p-5">
      <%= case @live do %>
        <% {:ok, live} -> %>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <span class="font-mono text-lg font-bold">{live.symbol}</span>
              <span class="badge badge-outline">{faction_label(@agent, live)}</span>
            </div>
            <div class="flex gap-8 text-sm">
              <div>
                <div class="text-xs opacity-60">Credits</div>
                <div class="font-mono font-semibold">{credits_label(live.credits)}</div>
              </div>
              <div>
                <div class="text-xs opacity-60">Headquarters</div>
                <div class="font-mono">{hq_label(@agent, live)}</div>
              </div>
            </div>
          </div>
        <% {:error, reason} -> %>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <span class="font-mono text-lg font-bold">{@agent.symbol}</span>
              <span class="badge badge-outline">{@agent.faction}</span>
            </div>
            <div class="alert alert-warning py-2 text-sm">{live_error(reason)}</div>
          </div>
      <% end %>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :ships, :any, required: true

  defp fleet_grid(assigns) do
    ~H"""
    <div>
      <div class="mb-3 flex items-center justify-between">
        <h3 class="text-sm font-semibold uppercase tracking-wider opacity-60">Fleet</h3>
        <span class="text-xs opacity-60">{fleet_count_label(@ships)}</span>
      </div>

      <%= case @ships do %>
        <% {:ok, ships} -> %>
          <div :if={ships == []} class="alert alert-outline">
            This agent has no ships.
          </div>
          <div :if={ships != []} class="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <.ship_card :for={ship <- ships} ship={ship} />
          </div>
        <% {:error, reason} -> %>
          <div class="alert alert-warning">{live_error(reason)}</div>
      <% end %>
    </div>
    """
  end

  attr :ship, :map, required: true

  defp ship_card(assigns) do
    ~H"""
    <div class="card bg-base-200 p-4">
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="font-mono font-semibold">{@ship.symbol}</span>
          <span class="badge badge-ghost badge-sm">{ship_role(@ship)}</span>
        </div>
        <span class={status_badge_class(@ship)}>{ship_status(@ship)}</span>
      </div>

      <div class="mt-4 grid grid-cols-2 gap-4 text-sm">
        <div>
          <div class="text-xs opacity-60">Location</div>
          <div class="font-mono">{ship_location(@ship)}</div>
        </div>
        <div>
          <div class="text-xs opacity-60">Cooldown</div>
          <div>{cooldown_label(@ship)}</div>
        </div>
      </div>

      <div class="mt-4">
        <div class="flex items-center justify-between text-xs">
          <span class="opacity-60">Fuel</span>
          <span class="font-mono">{fuel_label(@ship)}</span>
        </div>
        <progress
          :if={capacity(@ship.fuel) > 0}
          class="progress progress-primary mt-1 h-2"
          value={current(@ship.fuel)}
          max={capacity(@ship.fuel)}
        />
      </div>

      <div class="mt-3">
        <div class="flex items-center justify-between text-xs">
          <span class="opacity-60">Cargo</span>
          <span class="font-mono">{cargo_label(@ship)}</span>
        </div>
        <progress
          :if={capacity(@ship.cargo) > 0}
          class="progress progress-secondary mt-1 h-2"
          value={current(@ship.cargo)}
          max={capacity(@ship.cargo)}
        />
      </div>

      <div class="mt-4">
        <%= if in_transit?(@ship) do %>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <span class="badge badge-warning badge-sm">In transit</span>
            <span class="font-mono">{arrival_label(@ship)}</span>
          </div>
          <p class="mt-1 text-xs opacity-60">Actions resume when the ship arrives.</p>
        <% else %>
          <form
            phx-submit="navigate"
            phx-value-symbol={@ship.symbol}
            class="flex gap-2"
          >
            <input
              type="text"
              name="waypoint_symbol"
              value=""
              placeholder="Waypoint symbol"
              autocomplete="off"
              class="input input-sm input-bordered flex-1 font-mono"
            />
            <button type="submit" disabled={cooldown_active?(@ship)} class="btn btn-primary btn-sm">
              Navigate
            </button>
          </form>
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              disabled
              title="Dock arrives in a later milestone"
              class="btn btn-ghost btn-xs"
            >
              Dock
            </button>
            <button
              type="button"
              disabled
              title="Orbit arrives in a later milestone"
              class="btn btn-ghost btn-xs"
            >
              Orbit
            </button>
            <button
              type="button"
              disabled
              title="Extract arrives in a later milestone"
              class="btn btn-ghost btn-xs"
            >
              Extract
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  ## Display helpers

  defp faction_label(_agent, %{starting_faction: faction}) when is_binary(faction), do: faction
  defp faction_label(agent, _), do: agent.faction

  defp hq_label(_agent, %{headquarters: hq}) when is_binary(hq), do: hq
  defp hq_label(agent, _), do: agent.headquarters

  defp credits_label(nil), do: "—"

  defp credits_label(credits) when is_integer(credits),
    do: credits |> Integer.to_string() |> thousands()

  defp thousands(digits) when byte_size(digits) <= 3, do: digits

  defp thousands(digits) do
    {prefix, suffix} = String.split_at(digits, byte_size(digits) - 3)
    thousands(prefix) <> "," <> suffix
  end

  defp live_error(:ship_in_transit), do: "This ship is in transit; actions resume on arrival."
  defp live_error(:cooldown_active), do: "This ship is on cooldown; wait for it to end."
  defp live_error(:agent_token_missing), do: "No AgentToken stored for this agent."
  defp live_error(%{message: message}) when is_binary(message), do: message
  defp live_error(_), do: "The game API could not be reached."

  defp fleet_count_label({:ok, ships}), do: pluralize(length(ships), "ship")
  defp fleet_count_label({:error, _reason}), do: "—"

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(n, word), do: "#{n} #{word}s"

  defp ship_role(%{registration: %{role: role}}) when is_binary(role), do: role
  defp ship_role(_), do: "ship"

  defp ship_status(%{nav: %{status: status}}) when is_binary(status), do: status
  defp ship_status(_), do: "UNKNOWN"

  defp status_badge_class(%{nav: %{status: status}}) do
    case status do
      "DOCKED" -> "badge badge-info badge-sm"
      "IN_ORBIT" -> "badge badge-success badge-sm"
      "IN_TRANSIT" -> "badge badge-warning badge-sm"
      _ -> "badge badge-ghost badge-sm"
    end
  end

  defp status_badge_class(_), do: "badge badge-ghost badge-sm"

  defp ship_location(%{nav: %{waypoint_symbol: waypoint}}) when is_binary(waypoint), do: waypoint
  defp ship_location(_), do: "—"

  defp in_transit?(%{nav: %{status: "IN_TRANSIT"}}), do: true
  defp in_transit?(_), do: false

  defp cooldown_active?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds) and seconds > 0,
       do: true

  defp cooldown_active?(_), do: false

  defp arrival_label(%{nav: %{route: %{arrival: arrival}}}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} -> "arrives #{Calendar.strftime(due_at, "%m-%d %H:%M")} UTC"
      _ -> "arrives soon"
    end
  end

  defp arrival_label(_), do: "arrives soon"

  defp cooldown_label(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds) and seconds > 0 do
    "Cooldown #{seconds}s"
  end

  defp cooldown_label(_), do: "Ready"

  defp fuel_label(%{fuel: fuel}) do
    "#{current(fuel)} / #{capacity(fuel)}"
  end

  defp fuel_label(_), do: "—"

  defp cargo_label(%{cargo: cargo}) do
    "#{cargo_units(cargo)} / #{capacity(cargo)}"
  end

  defp cargo_label(_), do: "—"

  defp current(nil), do: 0
  defp current(%{current: current}) when is_integer(current), do: current
  defp current(_), do: 0

  defp cargo_units(nil), do: 0
  defp cargo_units(%{units: units}) when is_integer(units), do: units
  defp cargo_units(_), do: 0

  defp capacity(nil), do: 0
  defp capacity(%{capacity: capacity}) when is_integer(capacity), do: capacity
  defp capacity(_), do: 0
end
