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
    {:ok, assign(socket, operator: operator, overviews: overviews, cooldown_tick: 0)}
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
  def handle_event(action, %{"symbol" => ship_symbol}, socket)
      when action in ["dock", "orbit", "extract"] do
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

  defp purchase_flash(socket, nil), do: socket

  defp purchase_flash(socket, {:ship_record_failed, _reason}) do
    put_flash(socket, :info, "Ship purchased, but local restart recovery could not be recorded.")
  end

  ## Components

  attr :overviews, :list, required: true

  defp contract_hero(assigns) do
    ~H"""
    <div class="card border border-primary/30 bg-base-200 p-6">
      <div class="flex items-start justify-between gap-4">
        <div>
          <p class="text-xs uppercase tracking-wider opacity-60">Active mission</p>
          <%= if Enum.any?(@overviews, &active_contract?/1) do %>
            <h2 class="mt-1 text-xl font-bold">Contract in progress</h2>
            <p class="mt-1 text-sm opacity-70">Deliver the required goods before the deadline.</p>
          <% else %>
            <h2 class="mt-1 text-xl font-bold">No active mission</h2>
            <p class="mt-1 text-sm opacity-70">Accept a contract to start your first mission.</p>
          <% end %>
        </div>
        <span class="badge badge-outline">Missions</span>
      </div>
    </div>
    """
  end

  attr :overview, :map, required: true
  attr :cooldown_tick, :integer, required: true

  defp agent_section(assigns) do
    ~H"""
    <section class="space-y-4">
      <.agent_overview_card agent={@overview.agent} live={@overview.overview} />
      <.contract_panel contracts={@overview.contracts} agent_id={@overview.agent.id} />
      <.shipyard_panel listings={@overview.shipyards} agent_id={@overview.agent.id} />
      <.market_panel listings={@overview.markets} />
      <.fleet_grid
        agent={@overview.agent}
        ships={@overview.ships}
        cooldown_tick={@cooldown_tick}
      />
    </section>
    """
  end

  attr :contracts, :any, required: true
  attr :agent_id, :integer, required: true

  defp contract_panel(assigns) do
    ~H"""
    <%= case @contracts do %>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">Contracts unavailable: {live_error(reason)}</div>
      <% {:ok, []} -> %>
        <div class="alert alert-outline">No contracts available.</div>
      <% {:ok, contracts} -> %>
        <div :for={contract <- contracts} class="card border border-primary/30 bg-base-200 p-4">
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h3 class="font-semibold">{contract.type} · {contract.id}</h3>
              <p class="text-sm opacity-70">Deadline: {deadline_label(contract)}</p>
            </div>
            <span class="badge badge-outline">{contract_status(contract)}</span>
          </div>
          <div :for={good <- contract.terms.deliver || []} class="mt-4 space-y-2 text-sm">
            <div class="flex items-center justify-between">
              <span>{good.trade_symbol} to <span class="font-mono">{good.destination_symbol}</span></span>
              <span class="font-mono">{good.units_fulfilled} / {good.units_required}</span>
            </div>
            <form
              :if={contract.accepted && not contract.fulfilled}
              phx-submit="deliver_contract"
              class="flex flex-wrap gap-2"
            >
              <input type="hidden" name="agent_id" value={@agent_id} />
              <input type="hidden" name="contract_id" value={contract.id} />
              <input type="hidden" name="trade_symbol" value={good.trade_symbol} />
              <input
                name="ship_symbol"
                placeholder="Ship symbol"
                class="input input-bordered input-xs font-mono"
                required
              />
              <input
                name="units"
                type="number"
                min="1"
                max={good.units_required - good.units_fulfilled}
                value={good.units_required - good.units_fulfilled}
                class="input input-bordered input-xs w-20"
              />
              <button type="submit" class="btn btn-secondary btn-xs">Deliver</button>
            </form>
          </div>
          <form
            :if={not contract.accepted && not contract.fulfilled}
            phx-submit="accept_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button type="submit" class="btn btn-primary btn-sm">Accept contract</button>
          </form>
          <form
            :if={contract.accepted && not contract.fulfilled && contract_ready?(contract)}
            phx-submit="fulfill_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button type="submit" class="btn btn-primary btn-sm">Fulfill contract</button>
          </form>
        </div>
    <% end %>
    """
  end

  attr :listings, :any, required: true
  attr :agent_id, :integer, required: true

  defp shipyard_panel(assigns) do
    ~H"""
    <%= case @listings do %>
      <% {:ok, []} -> %>
        <div class="alert alert-outline">No shipyard is currently on-site.</div>
      <% {:ok, listings} -> %>
        <div class="card border border-primary/30 bg-base-200 p-4">
          <h3 class="font-semibold">Shipyard</h3>
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
      <% {:ok, listings} -> %>
        <div class="card border border-secondary/30 bg-base-200 p-4">
          <h3 class="font-semibold">Market</h3>
          <div :for={listing <- listings} class="mt-4 space-y-4">
            <div class="font-mono text-sm">{listing.waypoint}</div>
            <div :for={good <- listing.market.trade_goods || []} class="space-y-2">
              <div class="flex items-center justify-between gap-3 text-sm">
                <span>{good.symbol}</span>
                <span class="font-mono">Sell {credits_label(good.sell_price)} cr</span>
              </div>
              <form
                :for={ship <- listing.ships}
                :if={cargo_item(ship, good.symbol)}
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
            </div>
          </div>
        </div>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">{live_error(reason)}</div>
    <% end %>
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
  attr :cooldown_tick, :integer, required: true

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
              phx-click="dock"
              phx-value-symbol={@ship.symbol}
              disabled={not dockable?(@ship)}
              class="btn btn-ghost btn-xs"
            >
              Dock
            </button>
            <button
              type="button"
              phx-click="orbit"
              phx-value-symbol={@ship.symbol}
              disabled={not orbitable?(@ship)}
              class="btn btn-ghost btn-xs"
            >
              Orbit
            </button>
            <button
              type="button"
              phx-click="extract"
              phx-value-symbol={@ship.symbol}
              disabled={not extractable?(@ship)}
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

  defp capacity(nil), do: 0
  defp capacity(%{capacity: capacity}) when is_integer(capacity), do: capacity
  defp capacity(_), do: 0
end
