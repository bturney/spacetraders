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
  alias SpaceTraders.SystemWaypointProjection

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <%= if @operator do %>
        <div class="space-y-6">
          <div class="flex flex-col gap-5 sm:flex-row sm:items-end sm:justify-between">
            <div class="space-y-2">
              <p class="eyebrow">Operator command deck</p>
              <.header>
                Fleet command
                <:subtitle>
                  Learn the loop: choose a Mission, move a Ship, and watch your Fleet grow.
                </:subtitle>
              </.header>
            </div>
            <.link navigate={~p"/agents/new"} class="btn btn-primary min-h-12 shrink-0">Mint an agent</.link>
          </div>

          <.contract_hero overviews={@overviews} />

          <div :if={@overviews == []} class="alert alert-outline">
            You haven't minted any agents yet.
            <.link navigate={~p"/agents/new"} class="font-semibold underline">
              Mint your first agent
            </.link>
            .
          </div>

          <.agent_section
            :for={overview <- @overviews}
            overview={overview}
            cooldown_tick={@cooldown_tick}
            selected_waypoints={@selected_waypoints}
            waypoint_filters={@waypoint_filters}
          />
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

    overviews = Enum.map(agents, &Fleet.command_snapshot/1)

    Process.send_after(self(), :cooldown_tick, 1_000)

    {:ok,
     assign(socket,
       operator: operator,
       overviews: overviews,
       cooldown_tick: 0,
       selected_waypoints: %{},
       waypoint_filters: %{}
     )}
  end

  @impl true
  def handle_event(
        action,
        %{"symbol" => ship_symbol, "waypoint_symbol" => waypoint},
        socket
      )
      when action in ["navigate", "browser_navigate"] do
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
  def handle_event("extract", %{"symbol" => ship_symbol}, socket) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, result} <- Fleet.extract_resources(agent, ship_symbol) do
      socket =
        socket
        |> refresh_agent_fleet(agent.id)
        |> apply_ship_result(agent.id, ship_symbol, result)

      {:noreply, socket}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(action, %{"symbol" => ship_symbol}, socket)
      when action in ["dock", "orbit", "refuel"] do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, _result} <- ship_action(action, agent, ship_symbol) do
      {:noreply, refresh_agent_fleet(socket, agent.id)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "buy_ship",
        %{"agent_id" => agent_id, "ship_type" => ship_type, "waypoint" => waypoint},
        socket
      ) do
    with {:ok, snapshot} <- snapshot_for_purchase(socket, agent_id),
         {:ok, purchase} <- Fleet.purchase_ship(snapshot, ship_type, waypoint) do
      socket = refresh_agent(socket, snapshot.agent)
      socket = put_flash(socket, :info, "#{ship_type} purchased at #{waypoint}.")
      {:noreply, purchase_flash(socket, purchase.warning)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "sell_cargo",
        %{"symbol" => ship_symbol, "trade_symbol" => trade_symbol, "units" => units},
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, units} <- parse_units(units),
         {:ok, %{transaction: transaction}} <-
           Fleet.sell_cargo(agent, ship_symbol, trade_symbol, units) do
      socket = refresh_agent(socket, agent)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Sold #{transaction.units} #{trade_symbol} for #{transaction.total_price} credits."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "purchase_cargo",
        %{"symbol" => ship_symbol, "trade_symbol" => trade_symbol, "units" => units},
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, units} <- parse_units(units),
         {:ok, %{transaction: transaction}} <-
           Fleet.purchase_cargo(agent, ship_symbol, trade_symbol, units) do
      socket = refresh_agent(socket, agent)

      {:noreply,
       put_flash(
         socket,
         :info,
         "Bought #{transaction.units} #{trade_symbol} for #{transaction.total_price} credits."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "jettison_cargo",
        %{"symbol" => ship_symbol, "trade_symbol" => trade_symbol, "units" => units},
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, units} <- parse_units(units),
         {:ok, _result} <- Fleet.jettison_cargo(agent, ship_symbol, trade_symbol, units) do
      {:noreply,
       put_flash(
         refresh_agent_fleet(socket, agent.id),
         :info,
         "Jettisoned #{units} #{trade_symbol}."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event("select_waypoint", %{"agent_id" => agent_id, "symbol" => symbol}, socket) do
    selected_waypoints = Map.put(socket.assigns.selected_waypoints, agent_id, symbol)
    {:noreply, assign(socket, selected_waypoints: selected_waypoints)}
  end

  @impl true
  def handle_event("clear_waypoint", %{"agent_id" => agent_id}, socket) do
    {:noreply,
     assign(socket, selected_waypoints: Map.delete(socket.assigns.selected_waypoints, agent_id))}
  end

  @impl true
  def handle_event("filter_waypoints", %{"agent_id" => agent_id, "filter" => filter}, socket) do
    waypoint_filters = Map.put(socket.assigns.waypoint_filters, agent_id, filter)
    {:noreply, assign(socket, waypoint_filters: waypoint_filters)}
  end

  @impl true
  def handle_event(
        "accept_contract",
        %{"agent_id" => agent_id, "contract_id" => contract_id},
        socket
      ) do
    with {:ok, agent} <- agent_for_contract(socket, agent_id, contract_id),
         {:ok, _result} <- SpaceTraders.Contracts.accept_contract(agent, contract_id) do
      {:noreply, put_flash(refresh_agent(socket, agent), :info, "Contract accepted.")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "deliver_contract",
        %{
          "agent_id" => agent_id,
          "contract_id" => contract_id,
          "ship_symbol" => ship_symbol,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with {:ok, agent} <- agent_for_contract(socket, agent_id, contract_id),
         {:ok, units} <- parse_units(units),
         {:ok, _result} <-
           SpaceTraders.Contracts.deliver_goods(
             agent,
             contract_id,
             ship_symbol,
             trade_symbol,
             units
           ) do
      {:noreply,
       put_flash(refresh_agent(socket, agent), :info, "Delivered #{units} #{trade_symbol}.")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "fulfill_contract",
        %{"agent_id" => agent_id, "contract_id" => contract_id},
        socket
      ) do
    with {:ok, agent} <- agent_for_contract(socket, agent_id, contract_id),
         {:ok, _result} <- SpaceTraders.Contracts.fulfill_contract(agent, contract_id) do
      {:noreply,
       put_flash(refresh_agent(socket, agent), :info, "Contract fulfilled. Payment collected.")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "negotiate_contract",
        %{"agent_id" => agent_id, "ship_symbol" => ship_symbol},
        socket
      ) do
    with {:ok, agent} <- agent_for_negotiate(socket, agent_id, ship_symbol),
         {:ok, _result} <- SpaceTraders.Contracts.negotiate_contract(agent, ship_symbol) do
      {:noreply, put_flash(refresh_agent(socket, agent), :info, "New contract negotiated.")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_info({:ship_updated, agent_id, _ship_symbol}, socket) do
    {:noreply, refresh_agent_fleet(socket, agent_id)}
  end

  @impl true
  def handle_info(:cooldown_tick, socket) do
    Process.send_after(self(), :cooldown_tick, 1_000)
    {:noreply, update(socket, :cooldown_tick, &(&1 + 1))}
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

  defp agent_for_contract(socket, agent_id, contract_id) do
    Enum.find_value(
      socket.assigns.overviews,
      {:error, "That contract is not available."},
      fn overview ->
        if to_string(overview.agent.id) == agent_id and
             match?({:ok, contracts} when is_list(contracts), overview.contracts) and
             Enum.any?(elem(overview.contracts, 1), &(&1.id == contract_id)) do
          {:ok, overview.agent}
        end
      end
    )
  end

  defp agent_for_negotiate(socket, agent_id, ship_symbol) do
    Enum.find_value(
      socket.assigns.overviews,
      {:error, "That ship is not in this agent's fleet."},
      fn overview ->
        if to_string(overview.agent.id) == agent_id and
             match?({:ok, ships} when is_list(ships), overview.ships) and
             Enum.any?(elem(overview.ships, 1), &(&1.symbol == ship_symbol)) do
          {:ok, overview.agent}
        end
      end
    )
  end

  defp snapshot_for_purchase(socket, agent_id) do
    Enum.find_value(
      socket.assigns.overviews,
      {:error, "That shipyard is not available."},
      fn snapshot ->
        if to_string(snapshot.agent.id) == agent_id, do: {:ok, snapshot}
      end
    )
  end

  defp validate_waypoint(""), do: {:error, "Enter a target waypoint."}
  defp validate_waypoint(_waypoint), do: :ok

  defp parse_units(units) when is_integer(units) and units > 0, do: {:ok, units}

  defp parse_units(units) when is_binary(units) do
    case Integer.parse(units) do
      {units, ""} when units > 0 -> {:ok, units}
      _ -> {:error, "Enter a positive number of units."}
    end
  end

  defp parse_units(_), do: {:error, "Enter a positive number of units."}

  defp ship_action("dock", agent, ship_symbol), do: Fleet.dock_ship(agent, ship_symbol)
  defp ship_action("orbit", agent, ship_symbol), do: Fleet.orbit_ship(agent, ship_symbol)
  defp ship_action("extract", agent, ship_symbol), do: Fleet.extract_resources(agent, ship_symbol)
  defp ship_action("refuel", agent, ship_symbol), do: Fleet.refuel_ship(agent, ship_symbol)

  defp refresh_agent_fleet(socket, agent_id) do
    overview = Enum.find(socket.assigns.overviews, &(&1.agent.id == agent_id))
    if overview, do: refresh_agent(socket, overview.agent), else: socket
  end

  defp refresh_agent(socket, agent) do
    overviews =
      Enum.map(socket.assigns.overviews, fn overview ->
        if overview.agent.id == agent.id do
          Fleet.command_snapshot(agent)
        else
          overview
        end
      end)

    assign(socket, :overviews, overviews)
  end

  defp apply_ship_result(socket, agent_id, ship_symbol, result) do
    ship_fields = Map.take(result, [:cargo, :cooldown])

    update(socket, :overviews, fn overviews ->
      Enum.map(overviews, fn
        %{agent: %{id: ^agent_id}, ships: {:ok, ships}} = overview ->
          ships =
            Enum.map(ships, fn
              %{symbol: ^ship_symbol} = ship -> Map.merge(ship, ship_fields)
              ship -> ship
            end)

          %{overview | ships: {:ok, ships}}

        overview ->
          overview
      end)
    end)
  end

  defp purchase_flash(socket, nil), do: socket

  defp purchase_flash(socket, {:ship_record_failed, _reason}) do
    put_flash(socket, :info, "Ship purchased, but local restart recovery could not be recorded.")
  end

  ## Components

  attr :overviews, :list, required: true

  defp contract_hero(assigns) do
    ~H"""
    <div class="mission-hero card border border-primary/30 bg-base-200 p-5 sm:p-7">
      <div class="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <p class="eyebrow">What should I do next?</p>
          <%= if Enum.any?(@overviews, &active_contract?/1) do %>
            <h2 class="mt-2 text-2xl font-bold tracking-tight">Continue your Mission</h2>
            <p class="mt-2 max-w-2xl text-sm leading-6 opacity-70">
              A Contract is active. Check each Ship's location and cargo, then deliver the required goods before the Deadline.
            </p>
          <% else %>
            <h2 class="mt-2 text-2xl font-bold tracking-tight">Start your first Mission</h2>
            <p class="mt-2 max-w-2xl text-sm leading-6 opacity-70">
              Negotiate a new Contract with a faction waypoint your Ship is at, then accept it below and use a Ship to complete its first Leg.
            </p>
          <% end %>
        </div>
        <span class="badge badge-primary badge-outline self-start">Mission briefing</span>
      </div>
    </div>
    """
  end

  attr :overview, :map, required: true
  attr :cooldown_tick, :integer, required: true
  attr :selected_waypoints, :map, default: %{}
  attr :waypoint_filters, :map, default: %{}

  defp agent_section(assigns) do
    ~H"""
    <section class="space-y-5 border-t border-base-300/70 pt-6">
      <.agent_overview_card agent={@overview.agent} live={@overview.overview} />
      <.fleet_grid
        agent={@overview.agent}
        ships={@overview.ships}
        cooldown_tick={@cooldown_tick}
      />
      <div class="grid gap-5 lg:grid-cols-2">
        <.contract_panel
          contracts={@overview.contracts}
          ships={@overview.ships}
          agent_id={@overview.agent.id}
        />
        <div class="space-y-5">
          <.shipyard_panel listings={@overview.shipyards} agent_id={@overview.agent.id} />
          <.market_panel listings={@overview.markets} />
        </div>
      </div>
      <.system_map
        waypoints={@overview.waypoints}
        ships={@overview.ships}
        agent_id={@overview.agent.id}
        headquarters_system={headquarters_system(@overview.agent.headquarters)}
        selected_symbol={Map.get(@selected_waypoints, to_string(@overview.agent.id))}
        filter={Map.get(@waypoint_filters, to_string(@overview.agent.id), "all")}
      />
    </section>
    """
  end

  attr :contracts, :any, required: true
  attr :ships, :any, required: true
  attr :agent_id, :integer, required: true

  defp contract_panel(assigns) do
    ~H"""
    <%= case @contracts do %>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">Contracts unavailable: {live_error(reason)}</div>
      <% {:ok, []} -> %>
        <div class="card border border-primary/30 bg-base-200 p-4 sm:p-5">
          <p class="eyebrow">Mission briefing</p>
          <h3 class="mt-1 font-semibold">No contracts available</h3>
          <p class="mt-1 text-sm opacity-70">
            Negotiate a new contract with a faction waypoint your Ship is at.
          </p>
          <.negotiate_form ships={@ships} agent_id={@agent_id} />
        </div>
      <% {:ok, contracts} -> %>
        <div :for={contract <- contracts} class="card border border-primary/30 bg-base-200 p-4 sm:p-5">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <p class="eyebrow">Contract</p>
              <h3 class="mt-1 font-semibold">
                {contract.type} <span class="font-mono text-xs opacity-60">{contract.id}</span>
              </h3>
              <p class="text-sm opacity-70">Deadline: {deadline_label(contract)}</p>
            </div>
            <span class="badge badge-outline">{contract_status(contract)}</span>
          </div>
          <div :for={good <- contract.terms.deliver || []} class="mt-4 space-y-2 text-sm">
            <% delivery_ships = delivery_ships(@ships, good.destination_symbol, good.trade_symbol) %>
            <div class="flex items-center justify-between">
              <span>{good.trade_symbol} to <span class="font-mono">{good.destination_symbol}</span></span>
              <span class="font-mono">{good.units_fulfilled} / {good.units_required}</span>
            </div>
            <form
              :for={ship <- delivery_ships}
              :if={contract.accepted && not contract.fulfilled}
              phx-submit="deliver_contract"
              class="grid grid-cols-[minmax(0,1fr)_5rem_auto] gap-2 sm:flex"
            >
              <input type="hidden" name="agent_id" value={@agent_id} />
              <input type="hidden" name="contract_id" value={contract.id} />
              <input type="hidden" name="trade_symbol" value={good.trade_symbol} />
              <input type="hidden" name="ship_symbol" value={ship.symbol} />
              <span class="self-center font-mono text-xs">
                {ship.symbol} ({delivery_units(ship, good.trade_symbol)} available)
              </span>
              <input
                name="units"
                type="number"
                min="1"
                max={delivery_limit(ship, good)}
                value={delivery_limit(ship, good)}
                class="input input-bordered input-sm w-full sm:w-20"
                required
              />
              <button type="submit" class="btn btn-secondary btn-sm">Deliver</button>
            </form>
            <p
              :if={contract.accepted && not contract.fulfilled && delivery_ships == []}
              class="text-xs opacity-70"
            >
              No ship at this waypoint has {good.trade_symbol} to deliver.
            </p>
          </div>
          <form
            :if={not contract.accepted && not contract.fulfilled}
            phx-submit="accept_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button type="submit" class="btn btn-primary min-h-11 btn-sm">Accept contract</button>
          </form>
          <form
            :if={contract.accepted && not contract.fulfilled && contract_ready?(contract)}
            phx-submit="fulfill_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button type="submit" class="btn btn-primary min-h-11 btn-sm">Fulfill contract</button>
          </form>
        </div>
        <%= if negotiable?(@contracts) do %>
          <div class="card border border-primary/30 bg-base-200 p-4 sm:p-5">
            <p class="eyebrow">Mission briefing</p>
            <h3 class="mt-1 font-semibold">Negotiate a new contract</h3>
            <.negotiate_form ships={@ships} agent_id={@agent_id} />
          </div>
        <% end %>
    <% end %>
    """
  end

  attr :ships, :any, required: true
  attr :agent_id, :integer, required: true

  defp negotiate_form(assigns) do
    ~H"""
    <form phx-submit="negotiate_contract" class="mt-4">
      <input type="hidden" name="agent_id" value={@agent_id} />
      <%= case @ships do %>
        <% {:ok, ships} when ships != [] -> %>
          <label class="label">
            <span class="label-text">Ship at a faction waypoint</span>
          </label>
          <select
            name="ship_symbol"
            class="select select-bordered select-sm w-full font-mono"
            required
          >
            <option :for={ship <- ships} value={ship.symbol}>
              {ship.symbol} @ {ship_location(ship)}
            </option>
          </select>
        <% _ -> %>
          <input
            name="ship_symbol"
            placeholder="Ship symbol at a faction waypoint"
            class="input input-bordered input-sm w-full font-mono"
            required
          />
      <% end %>
      <button type="submit" class="btn btn-primary min-h-11 btn-sm mt-3">
        Negotiate contract
      </button>
    </form>
    """
  end

  attr :listings, :any, required: true
  attr :agent_id, :integer, required: true

  defp shipyard_panel(assigns) do
    ~H"""
    <%= case @listings do %>
      <% {:ok, []} -> %>
        <div class="alert alert-outline">No shipyard is currently on-site.</div>
      <% {status, listings} when status in [:ok, :partial] -> %>
        <div class="card border border-primary/30 bg-base-200 p-4 sm:p-5">
          <p class="eyebrow">Fleet expansion</p>
          <h3 class="mt-1 font-semibold">Shipyard</h3>
          <div :if={status == :partial} class="alert alert-warning mt-3">
            Some shipyards are unavailable.
          </div>
          <div :for={listing <- listings} class="mt-3 space-y-3">
            <div class="font-mono text-sm">{listing.waypoint}</div>
            <div
              :for={ship <- listing.shipyard.ships || []}
              class="flex items-center justify-between gap-3 text-sm"
            >
              <span>{ship.name || ship.type}</span>
              <form phx-submit="buy_ship" class="flex items-center gap-2">
                <input type="hidden" name="agent_id" value={@agent_id} />
                <input type="hidden" name="ship_type" value={ship.type} />
                <input type="hidden" name="waypoint" value={listing.waypoint} />
                <span class="font-mono">{credits_label(ship.purchase_price)} cr</span>
                <button type="submit" class="btn btn-primary btn-xs">Buy</button>
              </form>
            </div>
          </div>
        </div>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">{live_error(reason)}</div>
    <% end %>
    """
  end

  attr :listings, :any, required: true

  defp market_panel(assigns) do
    ~H"""
    <%= case @listings do %>
      <% {:ok, []} -> %>
        <div class="alert alert-outline">No market is available for an on-site ship.</div>
      <% {status, listings} when status in [:ok, :partial] -> %>
        <div class="card border border-secondary/30 bg-base-200 p-4 sm:p-5">
          <p class="eyebrow">Trade and cargo</p>
          <h3 class="mt-1 font-semibold">Market</h3>
          <p class="mt-1 text-sm opacity-70">
            A ship can sell only cargo listed at its current market. Navigate that ship to a market that
            trades its other cargo.
          </p>
          <div :if={status == :partial} class="alert alert-warning mt-3">
            Some markets are unavailable.
          </div>
          <div :for={listing <- listings} class="mt-4 space-y-4">
            <div class="font-mono text-sm">{listing.waypoint}</div>
            <div :for={good <- listing.market.trade_goods || []} class="space-y-2">
              <div class="flex items-center justify-between gap-3 text-sm">
                <span>{good.symbol}</span>
                <span class="font-mono">
                  Buy {credits_label(good.purchase_price)} cr <span class="opacity-50">·</span>
                  Sell {credits_label(good.sell_price)} cr
                </span>
              </div>
              <form
                :for={ship <- listing.ships}
                :if={sellable?(ship, good)}
                phx-submit="sell_cargo"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="trade_symbol" value={good.symbol} />
                <span class="flex-1 text-xs opacity-70">
                  {ship.symbol}: {cargo_units(cargo_item(ship, good.symbol))} units
                </span>
                <input
                  type="number"
                  name="units"
                  min="1"
                  max={cargo_units(cargo_item(ship, good.symbol))}
                  value={cargo_units(cargo_item(ship, good.symbol))}
                  class="input input-bordered input-xs w-20"
                />
                <button type="submit" class="btn btn-secondary btn-xs">Sell</button>
              </form>
              <form
                :for={ship <- listing.ships}
                :if={buyable?(ship, good)}
                phx-submit="purchase_cargo"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="trade_symbol" value={good.symbol} />
                <span class="flex-1 text-xs opacity-70">{ship.symbol}</span>
                <input
                  type="number"
                  name="units"
                  min="1"
                  max={cargo_space(ship, good)}
                  value="1"
                  class="input input-bordered input-xs w-20"
                />
                <button type="submit" class="btn btn-primary btn-xs">Buy</button>
              </form>
            </div>
          </div>
        </div>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">{live_error(reason)}</div>
    <% end %>
    """
  end

  attr :waypoints, :any, required: true
  attr :ships, :any, required: true
  attr :agent_id, :integer, required: true
  attr :headquarters_system, :string, default: nil
  attr :selected_symbol, :string, default: nil
  attr :filter, :string, default: "all"

  defp system_map(assigns) do
    projection =
      SystemWaypointProjection.project(
        assigns.waypoints,
        assigns.ships,
        assigns.headquarters_system,
        assigns.selected_symbol,
        assigns.filter
      )

    assigns =
      assigns
      |> assign(:projection, projection)
      |> assign(:all_waypoints, projection.available)
      |> assign(:map_waypoints, projection.positioned)
      |> assign(:system_symbol, assigns.headquarters_system)
      |> assign(:filtered_waypoints, projection.filtered)
      |> assign(:ships_at, projection.ships_at)
      |> assign(:filtered_set, MapSet.new(projection.filtered, & &1.symbol))
      |> assign(:transit_routes, projection.transit_routes)
      |> assign(:off_system_ships, projection.off_system)
      |> assign(:inter_system_transit_ships, projection.inter_system_transit)

    ~H"""
    <%= case @projection.waypoints do %>
      <% {:error, reason} -> %>
        <div class="card border border-base-300/70 bg-base-200 p-4 sm:p-5">
          <div class="alert alert-warning">System map unavailable: {live_error(reason)}</div>
        </div>
      <% {:ok, _waypoints} -> %>
        <div class="space-y-4">
          <div class="grid gap-4 lg:grid-cols-[minmax(18rem,0.8fr)_minmax(0,1.2fr)]">
            <div class="card border border-base-300/70 bg-base-200 p-4 sm:p-5">
              <div class="flex flex-wrap items-end justify-between gap-3">
                <div>
                  <p class="eyebrow">System map</p>
                  <h3 class="mt-1 font-semibold">Headquarters system</h3>
                </div>
                <p class="text-xs opacity-60">Scroll or pinch to zoom. Drag to pan.</p>
              </div>
              <%= if @map_waypoints == [] do %>
                <div class="alert alert-outline mt-3">
                  No coordinate data is available for this system.
                </div>
              <% else %>
                <div class="system-map-canvas bg-grid mt-4">
                  <svg
                    id={"system-map-#{@agent_id}"}
                    data-system-map
                    phx-hook="SystemMap"
                    viewBox={system_map_view_box(@map_waypoints)}
                    aria-label="Interactive system map. Use arrow keys to pan, plus and minus to zoom, and Home to reset."
                    tabindex="0"
                  >
                    <g class="system-map-axis">
                      <line x1="-10000" y1="0" x2="10000" y2="0" />
                      <line x1="0" y1="-10000" x2="0" y2="10000" />
                    </g>
                    <line
                      :for={route <- @transit_routes}
                      class="system-map-transit-route"
                      data-transit-route={route.ship.symbol}
                      x1={route.origin.x}
                      y1={route.origin.y}
                      x2={route.destination.x}
                      y2={route.destination.y}
                      aria-label={"#{route.ship.symbol} in transit from #{route.origin.symbol} to #{route.destination.symbol}"}
                    />
                    <g
                      :for={waypoint <- @map_waypoints}
                      data-waypoint-symbol={waypoint.symbol}
                      data-x={waypoint.x}
                      data-y={waypoint.y}
                      data-orbital-index={waypoint.orbital_index}
                      data-orbital-count={waypoint.orbital_count}
                      class={"system-map-waypoint #{waypoint_marker(waypoint.type)} #{selected_waypoint_class(waypoint, @selected_symbol)} #{filtered_waypoint_class(waypoint, @filtered_set)}"}
                      phx-click="select_waypoint"
                      phx-value-agent_id={@agent_id}
                      phx-value-symbol={waypoint.symbol}
                      role="button"
                      tabindex="0"
                      aria-label={waypoint_aria_label(waypoint)}
                      aria-pressed={to_string(waypoint.symbol == @selected_symbol)}
                    >
                      <title>{waypoint_aria_label(waypoint)}</title>
                      <circle class="system-map-hit-area" cx={waypoint.x} cy={waypoint.y} r="12" />
                      <circle
                        :if={waypoint_marker(waypoint.type) == "planet"}
                        cx={waypoint.x}
                        cy={waypoint.y}
                        r="6"
                      />
                      <rect
                        :if={waypoint_marker(waypoint.type) == "station"}
                        x={waypoint.x - 5}
                        y={waypoint.y - 5}
                        width="10"
                        height="10"
                      />
                      <path
                        :if={waypoint_marker(waypoint.type) == "asteroid"}
                        d={"M #{waypoint.x} #{waypoint.y - 6} L #{waypoint.x + 6} #{waypoint.y} L #{waypoint.x} #{waypoint.y + 6} L #{waypoint.x - 6} #{waypoint.y} Z"}
                      />
                      <path
                        :if={waypoint_marker(waypoint.type) == "other"}
                        d={"M #{waypoint.x} #{waypoint.y - 6} L #{waypoint.x + 5.2} #{waypoint.y - 3} L #{waypoint.x + 5.2} #{waypoint.y + 3} L #{waypoint.x} #{waypoint.y + 6} L #{waypoint.x - 5.2} #{waypoint.y + 3} L #{waypoint.x - 5.2} #{waypoint.y - 3} Z"}
                      />
                      <%= if ship_count_at(@ships_at, waypoint.symbol) > 0 do %>
                        <circle
                          class="system-map-ship-count-badge"
                          data-ship-count-badge={waypoint.symbol}
                          cx={waypoint.x + 5}
                          cy={waypoint.y - 6.5}
                          r="4"
                        />
                        <text
                          class="system-map-ship-count"
                          data-ship-count={waypoint.symbol}
                          x={waypoint.x + 5}
                          y={waypoint.y - 5}
                        >
                          {ship_count_at(@ships_at, waypoint.symbol)}
                        </text>
                      <% end %>
                      <text
                        :if={waypoint.symbol == @selected_symbol}
                        class="system-map-waypoint-label"
                        x={waypoint.x}
                        y={waypoint.y + 12}
                      >
                        {waypoint.symbol}
                      </text>
                    </g>
                  </svg>
                  <div class="system-map-controls" aria-label="Map controls">
                    <button
                      type="button"
                      class="btn btn-circle btn-sm"
                      data-map-control="zoom-in"
                      aria-label="Zoom in"
                    >+</button>
                    <button
                      type="button"
                      class="btn btn-circle btn-sm"
                      data-map-control="zoom-out"
                      aria-label="Zoom out"
                    >-</button>
                    <button type="button" class="btn btn-sm" data-map-control="reset">Reset</button>
                  </div>
                  <div
                    :if={@selected_symbol}
                    data-map-inspector
                    data-inspector-symbol={@selected_symbol}
                    class="system-map-inspector"
                    role="region"
                    aria-live="polite"
                    aria-labelledby={"waypoint-inspector-#{@agent_id}"}
                  >
                    <.waypoint_details
                      waypoint={@projection.selected}
                      ships={@ships}
                      ships_at={@ships_at}
                      agent_id={@agent_id}
                    />
                  </div>
                </div>
              <% end %>
              <p class="eyebrow">Type markers</p>
              <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs opacity-75">
                <span><i class="system-map-key planet"></i> Planet</span>
                <span><i class="system-map-key station"></i> Station</span>
                <span><i class="system-map-key asteroid"></i> Asteroid</span>
                <span><i class="system-map-key other"></i> Other</span>
              </div>
            </div>
            <.waypoint_grid
              waypoints={@filtered_waypoints}
              ships_at={@ships_at}
              agent_id={@agent_id}
              selected_symbol={@selected_symbol}
              filter={@filter}
            />
          </div>
          <.waypoint_details
            :if={@map_waypoints == [] and @selected_symbol}
            waypoint={@projection.selected}
            ships={@ships}
            ships_at={@ships_at}
            agent_id={@agent_id}
          />
          <.fleet_location_summary
            off_system_ships={@off_system_ships}
            inter_system_transit_ships={@inter_system_transit_ships}
          />
        </div>
    <% end %>
    """
  end

  attr :waypoints, :list, required: true
  attr :ships_at, :any, required: true
  attr :agent_id, :integer, required: true
  attr :selected_symbol, :string, default: nil
  attr :filter, :string, required: true

  defp waypoint_grid(assigns) do
    ~H"""
    <div class="card min-w-0 border border-base-300/70 bg-base-200 p-4 sm:p-5">
      <div class="flex flex-wrap items-end justify-between gap-3">
        <div>
          <p class="eyebrow">Waypoint grid</p>
          <h3 class="mt-1 font-semibold">Operational waypoints</h3>
        </div>
        <div class="flex flex-wrap gap-1" role="group" aria-label="Waypoint filters">
          <button
            :for={{label, value} <- SystemWaypointProjection.filter_options()}
            type="button"
            phx-click="filter_waypoints"
            phx-value-agent_id={@agent_id}
            phx-value-filter={value}
            class={"btn btn-xs #{if @filter == value, do: "btn-primary", else: "btn-ghost"}"}
          >{label}</button>
        </div>
      </div>
      <div class="mt-4 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>Waypoint</th><th>Type</th><th>Traits</th><th>Ships</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={waypoint <- @waypoints}
              data-waypoint-row={waypoint.symbol}
              phx-click="select_waypoint"
              phx-value-agent_id={@agent_id}
              phx-value-symbol={waypoint.symbol}
              phx-keydown="select_waypoint"
              phx-key="Enter"
              tabindex="0"
              role="button"
              aria-pressed={to_string(waypoint.symbol == @selected_symbol)}
              class={"cursor-pointer #{selected_waypoint_class(waypoint, @selected_symbol)}"}
            >
              <td class="font-mono text-xs font-semibold">{waypoint.symbol}</td><td>
                {waypoint.type}
              </td><td>
                <span :for={trait <- waypoint.traits || []} class="badge badge-outline badge-xs mr-1">{trait.symbol}</span><span
                  :if={(waypoint.traits || []) == []}
                  class="opacity-60"
                >None</span>
              </td><td>
                {ship_count_label(ships_at_waypoint(@ships_at, waypoint.symbol))}
              </td>
            </tr>
            <tr :if={@waypoints == []}>
              <td colspan="4" class="opacity-60">No waypoints match this filter.</td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  attr :waypoint, :any, default: nil
  attr :ships, :any, required: true
  attr :ships_at, :any, required: true
  attr :agent_id, :integer, required: true

  defp waypoint_details(assigns) do
    ~H"""
    <div class="card border border-base-300/70 bg-base-100 p-4 sm:p-5">
      <%= case @waypoint do %>
        <% nil -> %>
          <p class="text-sm opacity-60">Select a waypoint to inspect its type, traits, and ships.</p>
        <% waypoint -> %>
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h4 id={"waypoint-inspector-#{@agent_id}"} class="font-mono text-sm font-semibold">
                {waypoint.symbol}
              </h4><p class="mt-1 text-sm opacity-70">
                {waypoint.type}
              </p>
            </div><div class="flex items-center gap-2">
              <span class="badge badge-outline">{ship_count_label(
                ships_at_waypoint(@ships_at, waypoint.symbol)
              )}</span><button
                type="button"
                class="btn btn-ghost btn-circle btn-xs"
                phx-click="clear_waypoint"
                phx-value-agent_id={@agent_id}
                aria-label="Close waypoint inspector"
              >x</button>
            </div>
          </div>
          <div class="mt-4">
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Traits</p><div class="mt-2 flex flex-wrap gap-1">
              <span :for={trait <- waypoint.traits || []} class="badge badge-outline badge-sm">{trait.symbol}</span><span
                :if={(waypoint.traits || []) == []}
                class="text-sm opacity-60"
              >None</span>
            </div>
          </div>
          <div
            :if={local_ships_at_waypoint(@ships_at, waypoint.symbol) != []}
            class="mt-4"
          >
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Ships</p>
            <ul data-waypoint-ships class="mt-2 space-y-1 text-sm">
              <li :for={ship <- local_ships_at_waypoint(@ships_at, waypoint.symbol)}>
                <span class="font-mono">{ship.symbol}</span>
                <span class="opacity-70">{ship_status(ship)}</span>
              </li>
            </ul>
          </div>
          <div :if={waypoint.orbits || (waypoint.orbitals || []) != []} class="mt-4">
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">
              Orbital relationship
            </p>
            <p :if={waypoint.orbits} class="mt-2 text-sm">
              Orbits <span class="font-mono">{waypoint.orbits}</span>
            </p>
            <div :if={(waypoint.orbitals || []) != []} class="mt-2 flex flex-wrap gap-1">
              <span class="text-sm">Orbitals</span><span
                :for={orbital <- waypoint.orbitals}
                class="badge badge-outline badge-sm font-mono"
              >{orbital.symbol}</span>
            </div>
          </div>
          <p
            :if={is_integer(waypoint.x) and is_integer(waypoint.y)}
            class="mt-4 font-mono text-xs opacity-60"
          >
            {waypoint.x}, {waypoint.y}
          </p>
          <form
            :if={browser_ships(@ships, waypoint.system_symbol) != []}
            phx-submit="browser_navigate"
            class="mt-4"
          >
            <input type="hidden" name="waypoint_symbol" value={waypoint.symbol} /><label class="label py-1"><span class="label-text text-xs">Navigate a ship here</span></label><div class="flex gap-2">
              <select
                name="symbol"
                class="select select-bordered select-xs min-w-0 flex-1 font-mono"
                required
              ><option
                :for={ship <- browser_ships(@ships, waypoint.system_symbol)}
                value={ship.symbol}
              >
                {ship.symbol}
              </option></select><button
                type="submit"
                class="btn btn-primary btn-xs"
              >Navigate</button>
            </div>
          </form>
      <% end %>
    </div>
    """
  end

  attr :off_system_ships, :list, required: true
  attr :inter_system_transit_ships, :list, required: true

  defp fleet_location_summary(assigns) do
    ~H"""
    <div
      :if={@off_system_ships != [] or @inter_system_transit_ships != []}
      class="flex flex-wrap gap-2 text-sm"
    >
      <span :if={@off_system_ships != []} data-fleet-summary="off-system" class="badge badge-outline">
        {pluralize(length(@off_system_ships), "off-system ship")} at another system
      </span>
      <span
        :if={@inter_system_transit_ships != []}
        data-fleet-summary="inter-system-transit"
        class="badge badge-warning badge-outline"
      >
        {pluralize(length(@inter_system_transit_ships), "ship")} in inter-system transit
      </span>
    </div>
    """
  end

  attr :agent, :map, required: true
  attr :live, :any, required: true

  defp agent_overview_card(assigns) do
    ~H"""
    <div class="card border border-base-300/70 bg-base-200 p-4 sm:p-5">
      <%= case @live do %>
        <% {:ok, live} -> %>
          <div class="flex flex-wrap items-center justify-between gap-4">
            <div class="flex items-center gap-3">
              <span class="font-mono text-lg font-bold">{live.symbol}</span>
              <span class="badge badge-outline">{faction_label(@agent, live)}</span>
            </div>
            <div class="grid grid-cols-2 gap-5 text-sm sm:gap-8">
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
  attr :cooldown_tick, :integer, required: true

  defp fleet_grid(assigns) do
    ~H"""
    <div>
      <div class="mb-3 flex items-end justify-between">
        <div>
          <p class="eyebrow">Ship status</p>
          <h3 class="mt-1 text-lg font-semibold">Fleet</h3>
        </div>
        <span class="text-xs opacity-60">{fleet_count_label(@ships)}</span>
      </div>

      <%= case @ships do %>
        <% {:ok, ships} -> %>
          <div :if={ships == []} class="alert alert-outline">
            This agent has no ships.
          </div>
          <div :if={ships != []} class="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <.ship_card :for={ship <- ships} ship={ship} cooldown_tick={@cooldown_tick} />
          </div>
        <% {:error, reason} -> %>
          <div class="alert alert-warning">{live_error(reason)}</div>
      <% end %>
    </div>
    """
  end

  attr :ship, :map, required: true
  attr :cooldown_tick, :integer, default: 0

  defp ship_card(assigns) do
    ~H"""
    <div class="card border border-base-300/70 bg-base-200 p-4 sm:p-5">
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="font-mono font-semibold">{@ship.symbol}</span>
          <span class="badge badge-ghost badge-sm">{ship_role(@ship)}</span>
        </div>
        <span class={status_badge_class(@ship)}>{ship_status(@ship)}</span>
      </div>

      <div class="mt-4 grid grid-cols-2 gap-4 border-y border-base-300/60 py-4 text-sm">
        <div>
          <div class="text-xs opacity-60">Location</div>
          <div class="font-mono">{ship_location(@ship)}</div>
        </div>
        <div>
          <div class="text-xs opacity-60">Cooldown</div>
          <div>{cooldown_label(@ship, @cooldown_tick)}</div>
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
          value={cargo_units(@ship.cargo)}
          max={capacity(@ship.cargo)}
        />
        <div
          :for={item <- cargo_inventory(@ship)}
          class="mt-2 flex items-center justify-between gap-2 rounded border border-base-300/50 px-3 py-2 text-sm"
        >
          <div>
            <span class="font-mono font-semibold">{item.symbol}</span>
            <span class="ml-2 opacity-60">{item.units} units</span>
          </div>
          <form phx-submit="jettison_cargo" class="flex items-center gap-2">
            <input type="hidden" name="symbol" value={@ship.symbol} />
            <input type="hidden" name="trade_symbol" value={item.symbol} />
            <input
              type="number"
              name="units"
              min="1"
              max={item.units}
              value={item.units}
              class="input input-bordered input-xs w-16"
            />
            <button type="submit" class="btn btn-ghost btn-xs">Jettison</button>
          </form>
        </div>
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
              class="input input-sm input-bordered min-h-11 flex-1 font-mono"
            />
            <button
              type="submit"
              disabled={cooldown_active?(@ship)}
              class="btn btn-primary min-h-11 btn-sm"
            >
              Navigate
            </button>
          </form>
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              type="button"
              phx-click="dock"
              phx-value-symbol={@ship.symbol}
              disabled={not dockable?(@ship)}
              class="btn btn-ghost min-h-10 btn-sm"
            >
              Dock
            </button>
            <button
              type="button"
              phx-click="orbit"
              phx-value-symbol={@ship.symbol}
              disabled={not orbitable?(@ship)}
              class="btn btn-ghost min-h-10 btn-sm"
            >
              Orbit
            </button>
            <button
              type="button"
              phx-click="extract"
              phx-value-symbol={@ship.symbol}
              disabled={not extractable?(@ship)}
              class="btn btn-ghost min-h-10 btn-sm"
            >
              Extract
            </button>
            <button
              type="button"
              phx-click="refuel"
              phx-value-symbol={@ship.symbol}
              disabled={not refuelable?(@ship)}
              class="btn btn-ghost min-h-10 btn-sm"
            >
              Refuel
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  ## Display helpers

  defp active_contract?(%{contracts: {:ok, contracts}}),
    do: Enum.any?(contracts, &(&1.accepted and not &1.fulfilled))

  defp active_contract?(_), do: false

  defp contract_status(%{fulfilled: true}), do: "FULFILLED"
  defp contract_status(%{accepted: true}), do: "ACCEPTED"
  defp contract_status(_), do: "PENDING"

  defp deadline_label(%{terms: %{deadline: deadline}}) when is_binary(deadline) do
    case DateTime.from_iso8601(deadline) do
      {:ok, date_time, _offset} -> Calendar.strftime(date_time, "%m-%d %H:%M UTC")
      _ -> "unknown"
    end
  end

  defp deadline_label(_), do: "unknown"

  defp contract_ready?(%{terms: %{deliver: deliver}}) when is_list(deliver) do
    Enum.all?(deliver, &(&1.units_fulfilled >= &1.units_required))
  end

  defp contract_ready?(_), do: false

  defp negotiable?({:ok, contracts}) when is_list(contracts) do
    not Enum.any?(contracts, &(not &1.accepted and not &1.fulfilled)) and
      not Enum.any?(contracts, &(&1.accepted and not &1.fulfilled))
  end

  defp negotiable?(_), do: false

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

  defp live_error(:insufficient_credits),
    do: "The agent does not have enough credits for that ship."

  defp live_error(:shipyard_unavailable), do: "That shipyard is not available."
  defp live_error(:market_unavailable), do: "That market is not available."
  defp live_error(:invalid_units), do: "Enter a positive number of units."
  defp live_error(:invalid_contract_deadline), do: "The contract deadline could not be read."

  defp live_error(%{type: :contract_expired}), do: "This contract has expired."

  defp live_error(%{type: :contract_not_accepted}),
    do: "Accept this contract before delivering goods."

  defp live_error(%{type: :contract_fulfilled}), do: "This contract has already been fulfilled."

  defp live_error(%{type: :insufficient_credits}),
    do: "The agent does not have enough credits for that ship."

  defp live_error(%{message: message}) when is_binary(message), do: message
  defp live_error(message) when is_binary(message), do: message

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

  defp dockable?(ship), do: not cooldown_active?(ship) and ship_status(ship) == "IN_ORBIT"
  defp orbitable?(ship), do: not cooldown_active?(ship) and ship_status(ship) == "DOCKED"
  defp extractable?(ship), do: not cooldown_active?(ship) and ship_status(ship) == "IN_ORBIT"
  defp refuelable?(ship), do: not cooldown_active?(ship) and ship_status(ship) == "DOCKED"

  defp arrival_label(%{nav: %{route: %{arrival: arrival}}}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} -> "arrives #{Calendar.strftime(due_at, "%m-%d %H:%M")} UTC"
      _ -> "arrives soon"
    end
  end

  defp arrival_label(_), do: "arrives soon"

  defp cooldown_label(%{cooldown: %{remaining_seconds: seconds, expiration: expiration}}, _tick)
       when is_integer(seconds) and seconds > 0 do
    remaining = countdown_seconds(seconds, expiration)
    if remaining > 0, do: "Cooldown #{remaining}s", else: "Ready"
  end

  defp cooldown_label(_, _tick), do: "Ready"

  defp countdown_seconds(fallback, expiration) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, due_at, _offset} -> max(DateTime.diff(due_at, DateTime.utc_now(), :second), 0)
      _ -> fallback
    end
  end

  defp countdown_seconds(fallback, _expiration), do: fallback

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

  defp cargo_item(%{cargo: %{inventory: inventory}}, symbol) when is_list(inventory) do
    Enum.find(inventory, &(&1.symbol == symbol))
  end

  defp cargo_item(_, _), do: nil

  defp delivery_ships({:ok, ships}, destination, trade_symbol) when is_list(ships) do
    Enum.filter(ships, fn ship ->
      not in_transit?(ship) and ship_location(ship) == destination and
        delivery_units(ship, trade_symbol) > 0
    end)
  end

  defp delivery_ships(_, _, _), do: []

  defp delivery_limit(ship, good) do
    min(delivery_units(ship, good.trade_symbol), good.units_required - good.units_fulfilled)
  end

  defp delivery_units(ship, trade_symbol) do
    case cargo_item(ship, trade_symbol) do
      %{units: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp cargo_inventory(%{cargo: %{inventory: inventory}}) when is_list(inventory), do: inventory
  defp cargo_inventory(_), do: []

  defp sellable?(ship, good), do: cargo_item(ship, good.symbol) != nil

  defp buyable?(ship, good) do
    (good.purchase_price || 0) > 0 and cargo_space(ship, good) > 0
  end

  defp cargo_space(ship, good) do
    space = capacity(ship.cargo) - cargo_units(ship.cargo)

    case good.trade_volume do
      volume when is_integer(volume) and volume > 0 -> min(space, volume)
      _ -> space
    end
  end

  defp ships_at_waypoint(:unavailable, _symbol), do: :unavailable
  defp ships_at_waypoint(ships_at, symbol), do: length(Map.get(ships_at, symbol, []))

  defp local_ships_at_waypoint(:unavailable, _symbol), do: []
  defp local_ships_at_waypoint(ships_at, symbol), do: Map.get(ships_at, symbol, [])

  defp ship_count_at(ships_at, symbol) do
    case ships_at_waypoint(ships_at, symbol) do
      :unavailable -> 0
      count -> count
    end
  end

  defp ship_count_label(:unavailable), do: "Unavailable"
  defp ship_count_label(count), do: pluralize(count, "ship")

  defp headquarters_system(headquarters) when is_binary(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> system
      _ -> nil
    end
  end

  defp headquarters_system(_), do: nil

  defp browser_ships({:ok, ships}, system_symbol) when is_list(ships) do
    Enum.filter(ships, &(&1.nav.status == "IN_ORBIT" and &1.nav.system_symbol == system_symbol))
  end

  defp browser_ships(_, _), do: []

  defp system_map_view_box(waypoints) do
    xs = Enum.map(waypoints, & &1.x)
    ys = Enum.map(waypoints, & &1.y)
    padding = max(20, ceil(max(Enum.max(xs) - Enum.min(xs), Enum.max(ys) - Enum.min(ys)) * 0.25))
    min_x = Enum.min(xs) - padding
    min_y = Enum.min(ys) - padding
    width = max(Enum.max(xs) - Enum.min(xs) + padding * 2, 20)
    height = max(Enum.max(ys) - Enum.min(ys) + padding * 2, 20)

    "#{min_x} #{min_y} #{width} #{height}"
  end

  defp waypoint_marker(type) when type in ["PLANET", "MOON", "GAS_GIANT"], do: "planet"
  defp waypoint_marker(type) when type in ["ORBITAL_STATION", "JUMP_GATE"], do: "station"

  defp waypoint_marker(type) when is_binary(type) do
    if String.contains?(type, "ASTEROID"), do: "asteroid", else: "other"
  end

  defp waypoint_marker(_), do: "other"

  defp waypoint_aria_label(%{orbits: parent, symbol: symbol}) when is_binary(parent),
    do: "Select #{symbol}, orbiting #{parent}"

  defp waypoint_aria_label(%{symbol: symbol}), do: "Select #{symbol}"

  defp selected_waypoint_class(%{symbol: symbol}, symbol), do: "selected"
  defp selected_waypoint_class(_, _), do: ""

  defp filtered_waypoint_class(waypoint, filtered_set) do
    if MapSet.member?(filtered_set, waypoint.symbol), do: "", else: "muted"
  end

  defp capacity(nil), do: 0
  defp capacity(%{capacity: capacity}) when is_integer(capacity), do: capacity
  defp capacity(_), do: 0
end
