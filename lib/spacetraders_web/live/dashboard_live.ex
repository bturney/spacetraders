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

  ## Form state across patches

  This view patches roughly once a second (`:cooldown_tick`) and on every fleet
  push (`{:ship_updated, ...}`). LiveView re-applies server-rendered `value`
  attributes to non-focused inputs on each patch, so a user-typed draft wipes
  itself out unless the server is the source of truth for the draft.

  Rule: any user-editable input bound to server data must be tracked with
  `phx-change` into a socket assign (see `@form_drafts`), never rendered
  with a bare server `value`. Client-side preservation hooks (like the
  `onBeforeElUpdated` details fix) only paper over one element kind at a time.
  """

  use SpaceTradersWeb, :live_view

  alias SpaceTraders.Agent
  alias SpaceTraders.Contracts
  alias SpaceTraders.Fleet
  alias SpaceTraders.SystemWaypointProjection
  alias SpaceTradersWeb.DashboardPrototype

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <%= if @prototype_variant do %>
        <DashboardPrototype.render variant={@prototype_variant} />
      <% else %>
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
              form_drafts={@form_drafts}
              selected_waypoints={@selected_waypoints}
              waypoint_filters={@waypoint_filters}
              expanded_market_descriptions={@expanded_market_descriptions}
              show_historical_contracts={@show_historical_contracts}
              waypoint_markets={@waypoint_markets}
              selected_ships={@selected_ships}
            />

            <.activity_panel overviews={@overviews} />
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
      <% end %>
    </Layouts.app>
    """
  end

  @impl true
  def mount(params, _session, socket) do
    socket = assign(socket, :prototype_variant, prototype_variant(params["prototype"]))

    if socket.assigns.prototype_variant do
      {:ok, socket}
    else
      case socket.assigns.current_scope do
        nil -> mount_anonymous(socket)
        %{operator: operator} -> mount_operator(socket, operator)
      end
    end
  end

  defp mount_anonymous(socket) do
    if Agent.has_operators?() do
      {:ok, assign(socket, :operator, nil)}
    else
      {:ok, redirect(socket, to: ~p"/setup")}
    end
  end

  defp prototype_variant(variant) when variant in ["a", "b", "c"], do: variant
  defp prototype_variant(_variant), do: nil

  defp previous_prototype("a"), do: "c"
  defp previous_prototype("b"), do: "a"
  defp previous_prototype("c"), do: "b"
  defp previous_prototype(_variant), do: "a"

  defp next_prototype("a"), do: "b"
  defp next_prototype("b"), do: "c"
  defp next_prototype("c"), do: "a"
  defp next_prototype(_variant), do: "a"

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
       form_drafts: %{},
       expanded_market_descriptions: MapSet.new(),
       show_historical_contracts: MapSet.new(),
       selected_waypoints: %{},
       selected_ships: %{},
       waypoint_filters: %{},
       waypoint_markets: %{}
     )}
  end

  @impl true
  def handle_event(
        action,
        %{"symbol" => ship_symbol, "waypoint_symbol" => waypoint} = params,
        socket
      )
      when action in ["navigate", "browser_navigate"] do
    waypoint = String.trim(waypoint || "")

    drafted_key =
      if action == "browser_navigate",
        do: params["draft_key"] || draft_key("browser_navigate", [waypoint]),
        else: draft_key("navigate", [ship_symbol])

    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- validate_waypoint(waypoint) do
      case Fleet.navigate_ship(agent, ship_symbol, waypoint) do
        {:ok, %{nav: %{route: %{destination: %{symbol: destination}}}}} ->
          {:noreply,
           put_flash(
             refresh_and_clear(socket, agent.id, drafted_key),
             :info,
             "#{ship_symbol} is in transit to #{destination}."
           )}

        {:ok, _result} ->
          {:noreply,
           put_flash(
             refresh_and_clear(socket, agent.id, drafted_key),
             :info,
             "#{ship_symbol} is in transit."
           )}

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

      {:noreply, extraction_flash(socket, result)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event("siphon", %{"symbol" => ship_symbol}, socket) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, result} <- Fleet.siphon_resources(agent, ship_symbol) do
      socket =
        socket
        |> refresh_agent_fleet(agent.id)
        |> apply_ship_result(agent.id, ship_symbol, result)

      {:noreply, siphon_flash(socket, result)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event("track_draft", %{"draft_key" => key} = params, socket) do
    draft = Map.drop(params, ["draft_key"])

    {:noreply, update(socket, :form_drafts, &Map.put(&1, key, draft))}
  end

  @impl true
  def handle_event("select_ship", %{"agent_id" => agent_id, "symbol" => symbol}, socket) do
    {:noreply, update(socket, :selected_ships, &Map.put(&1, agent_id, symbol))}
  end

  @impl true
  def handle_event("clear_ship", %{"agent_id" => agent_id}, socket) do
    {:noreply, update(socket, :selected_ships, &Map.delete(&1, agent_id))}
  end

  @impl true
  def handle_event("configure_autopilot", params, socket) do
    with {:ok, agent} <- agent_for_ship(socket, params["ship_symbol"]),
         {:ok, threshold} <- parse_units(params["cargo_threshold"]),
         {:ok, _config} <-
           Fleet.configure_autopilot(agent, params["ship_symbol"], %{
             extraction_waypoint: String.trim(params["extraction_waypoint"] || ""),
             market_waypoint: String.trim(params["market_waypoint"] || ""),
             cargo_threshold: threshold
           }) do
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("autopilot", [params["ship_symbol"]]))

      {:noreply,
       put_flash(
         socket,
         :info,
         "Autopilot configuration saved. Start remains manual."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event("start_autopilot", %{"symbol" => ship_symbol}, socket) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, _config} <- Fleet.start_autopilot(agent, ship_symbol) do
      {:noreply,
       put_flash(refresh_agent(socket, agent), :info, "#{ship_symbol} Autopilot is ready.")}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
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
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("sell", [ship_symbol, trade_symbol]))

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
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("purchase", [ship_symbol, trade_symbol]))

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
         refresh_agent_fleet(socket, agent.id)
         |> clear_draft(draft_key("jettison", [ship_symbol, trade_symbol])),
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
    key = {agent_id, symbol}

    socket =
      case Map.get(socket.assigns.waypoint_markets, key) do
        {:ok, _market} -> socket
        :not_a_marketplace -> socket
        {:error, _reason} -> load_waypoint_market(socket, agent_id, symbol, key)
        nil -> load_waypoint_market(socket, agent_id, symbol, key)
      end

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
        "toggle_market_description",
        %{"agent_id" => agent_id, "waypoint" => waypoint, "symbol" => symbol},
        socket
      ) do
    key = {agent_id, waypoint, symbol}
    expanded = socket.assigns.expanded_market_descriptions

    expanded =
      if MapSet.member?(expanded, key),
        do: MapSet.delete(expanded, key),
        else: MapSet.put(expanded, key)

    {:noreply, assign(socket, expanded_market_descriptions: expanded)}
  end

  @impl true
  def handle_event("toggle_historical_contracts", %{"agent_id" => agent_id}, socket) do
    shown = socket.assigns.show_historical_contracts

    shown =
      if MapSet.member?(shown, agent_id),
        do: MapSet.delete(shown, agent_id),
        else: MapSet.put(shown, agent_id)

    {:noreply, assign(socket, show_historical_contracts: shown)}
  end

  @impl true
  def handle_event(
        "accept_contract",
        %{"agent_id" => agent_id, "contract_id" => contract_id},
        socket
      ) do
    with {:ok, agent, contract} <- agent_for_contract(socket, agent_id, contract_id),
         true <- Contracts.acceptable?(contract),
         {:ok, _result} <- SpaceTraders.Contracts.accept_contract(agent, contract_id) do
      {:noreply, put_flash(refresh_agent(socket, agent), :info, "Contract accepted.")}
    else
      false -> {:noreply, put_flash(socket, :error, "This contract is no longer actionable.")}
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
    with {:ok, agent, contract} <- agent_for_contract(socket, agent_id, contract_id),
         true <- Contracts.fulfillable?(contract),
         {:ok, units} <- parse_units(units),
         {:ok, _result} <-
           SpaceTraders.Contracts.deliver_goods(
             agent,
             contract_id,
             ship_symbol,
             trade_symbol,
             units
           ) do
      socket =
        refresh_agent(socket, agent)
        |> clear_draft(draft_key("deliver", [ship_symbol, contract_id, trade_symbol]))

      {:noreply, put_flash(socket, :info, "Delivered #{units} #{trade_symbol}.")}
    else
      false -> {:noreply, put_flash(socket, :error, "This contract is no longer actionable.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "fulfill_contract",
        %{"agent_id" => agent_id, "contract_id" => contract_id},
        socket
      ) do
    with {:ok, agent, contract} <- agent_for_contract(socket, agent_id, contract_id),
         true <- Contracts.fulfillable?(contract),
         {:ok, _result} <- SpaceTraders.Contracts.fulfill_contract(agent, contract_id) do
      {:noreply,
       put_flash(refresh_agent(socket, agent), :info, "Contract fulfilled. Payment collected.")}
    else
      false -> {:noreply, put_flash(socket, :error, "This contract is no longer actionable.")}
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
      {:noreply,
       put_flash(
         refresh_agent(socket, agent)
         |> clear_draft(draft_key("negotiate", [agent_id])),
         :info,
         "New contract negotiated."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event("prototype_variant", %{"variant" => variant}, socket) do
    {:noreply, push_patch(socket, to: "/?prototype=#{prototype_variant(variant)}")}
  end

  def handle_event("prototype_variant", %{"key" => "ArrowLeft"}, socket) do
    {:noreply,
     push_patch(socket, to: "/?prototype=#{previous_prototype(socket.assigns.prototype_variant)}")}
  end

  def handle_event("prototype_variant", %{"key" => "ArrowRight"}, socket) do
    {:noreply,
     push_patch(socket, to: "/?prototype=#{next_prototype(socket.assigns.prototype_variant)}")}
  end

  @impl true
  def handle_event(action, %{"symbol" => ship_symbol}, socket)
      when action in ["pause_autopilot", "resume_autopilot", "stop_autopilot"] do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- autopilot_action(action, agent, ship_symbol) do
      message =
        case action do
          "pause_autopilot" -> "#{ship_symbol} Autopilot paused."
          "resume_autopilot" -> "#{ship_symbol} Autopilot resumed after revalidation."
          "stop_autopilot" -> "#{ship_symbol} Autopilot stopped; Ship is manual."
        end

      {:noreply, put_flash(refresh_agent(socket, agent), :info, message)}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
    end
  end

  defp autopilot_action("pause_autopilot", agent, ship),
    do: unwrap_config(Fleet.pause_autopilot(agent, ship))

  defp autopilot_action("resume_autopilot", agent, ship),
    do: unwrap_config(Fleet.resume_autopilot(agent, ship))

  defp autopilot_action("stop_autopilot", agent, ship), do: Fleet.stop_autopilot(agent, ship)
  defp unwrap_config({:ok, _config}), do: :ok
  defp unwrap_config(error), do: error

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
          {:ok, overview.agent, Enum.find(elem(overview.contracts, 1), &(&1.id == contract_id))}
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
             match?({:ok, contracts} when is_list(contracts), overview.contracts) and
             Contracts.negotiable?(elem(overview.contracts, 1)) and
             Enum.any?(elem(overview.ships, 1), &(&1.symbol == ship_symbol)) do
          {:ok, overview.agent}
        end
      end
    )
  end

  defp contract_dom_id(contract),
    do: "contract-" <> Base.url_encode64(contract.id, padding: false)

  defp visible_contracts(contracts, true), do: contracts

  defp visible_contracts(contracts, false),
    do: Enum.reject(contracts, &Contracts.historical?/1)

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

  defp load_waypoint_market(socket, agent_id, symbol, key) do
    result =
      case Enum.find(socket.assigns.overviews, &(to_string(&1.agent.id) == agent_id)) do
        nil ->
          {:error, :waypoint_unavailable}

        %{waypoints: {:ok, waypoints}, agent: %{agent_token: token}} when is_list(waypoints) ->
          case Enum.find(waypoints, &(&1.symbol == symbol)) do
            nil -> {:error, :waypoint_unavailable}
            waypoint -> fetch_waypoint_market(token, waypoint)
          end

        _ ->
          {:error, :waypoint_unavailable}
      end

    case result do
      {:ok, _market} -> update(socket, :waypoint_markets, &Map.put(&1, key, result))
      :not_a_marketplace -> update(socket, :waypoint_markets, &Map.put(&1, key, result))
      {:error, _reason} -> update(socket, :waypoint_markets, &Map.put(&1, key, result))
    end
  end

  defp fetch_waypoint_market(token, waypoint) do
    cond do
      not marketplace_waypoint?(waypoint) -> :not_a_marketplace
      not is_binary(token) or token == "" -> {:error, :agent_token_missing}
      true -> SpaceTraders.API.get_market(token, waypoint.system_symbol, waypoint.symbol)
    end
  end

  defp marketplace_waypoint?(waypoint),
    do: Enum.any?(waypoint.traits || [], &(&1.symbol == "MARKETPLACE"))

  defp refresh_agent_for_ship(socket, ship_symbol) do
    case agent_for_ship(socket, ship_symbol) do
      {:ok, agent} -> refresh_agent(socket, agent)
      _ -> socket
    end
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

  defp clear_draft(socket, key) do
    update(socket, :form_drafts, &Map.delete(&1, key))
  end

  defp refresh_and_clear(socket, agent_id, key) do
    socket
    |> refresh_agent_fleet(agent_id)
    |> clear_draft(key)
  end

  defp draft_key(prefix, parts) do
    Enum.join([prefix | parts], ":")
  end

  defp draft_field(drafts, prefix, parts, field, fallback) do
    key = draft_key(prefix, parts)

    case drafts do
      %{^key => params} -> Map.get(params, field, fallback)
      _ -> fallback
    end
  end

  defp draft_option_selected?(drafts, prefix, parts, field, value) do
    draft_field(drafts, prefix, parts, field, nil) == value
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

  defp extraction_flash(socket, %{extraction: %{yield: %{symbol: symbol, units: units}}}) do
    put_flash(socket, :info, "Extracted #{units} #{symbol}.")
  end

  defp extraction_flash(socket, _result), do: socket

  defp siphon_flash(socket, %{siphon: %{yield: %{symbol: symbol, units: units}}}) do
    put_flash(socket, :info, "Siphoned #{units} #{symbol}.")
  end

  defp siphon_flash(socket, _result), do: socket

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
  attr :form_drafts, :map, default: %{}
  attr :selected_waypoints, :map, default: %{}
  attr :waypoint_filters, :map, default: %{}
  attr :expanded_market_descriptions, :any, default: MapSet.new()
  attr :show_historical_contracts, :any, default: MapSet.new()
  attr :waypoint_markets, :map, default: %{}
  attr :selected_ships, :map, default: %{}

  defp agent_section(assigns) do
    ~H"""
    <section class="space-y-5 border-t border-base-300/70 pt-6">
      <.agent_overview_card agent={@overview.agent} live={@overview.overview} />
      <.fleet_grid
        agent={@overview.agent}
        ships={@overview.ships}
        cooldown_tick={@cooldown_tick}
        form_drafts={@form_drafts}
        selected_ship={Map.get(@selected_ships, to_string(@overview.agent.id))}
      />
      <div class="grid gap-5 lg:grid-cols-2">
        <.contract_panel
          contracts={@overview.contracts}
          ships={@overview.ships}
          agent_id={@overview.agent.id}
          form_drafts={@form_drafts}
          show_historical={MapSet.member?(@show_historical_contracts, to_string(@overview.agent.id))}
        />
        <div class="space-y-5">
          <.shipyard_panel
            listings={@overview.shipyards}
            agent_id={@overview.agent.id}
            credits={live_credits(@overview.overview)}
          />
          <.market_panel
            listings={@overview.markets}
            agent_id={@overview.agent.id}
            expanded_descriptions={@expanded_market_descriptions}
            form_drafts={@form_drafts}
          />
        </div>
      </div>
      <.system_map
        waypoints={@overview.waypoints}
        ships={@overview.ships}
        agent_id={@overview.agent.id}
        headquarters_system={headquarters_system(@overview.agent.headquarters)}
        selected_symbol={Map.get(@selected_waypoints, to_string(@overview.agent.id))}
        filter={Map.get(@waypoint_filters, to_string(@overview.agent.id), "all")}
        waypoint_markets={@waypoint_markets}
        form_drafts={@form_drafts}
      />
    </section>
    """
  end

  attr :contracts, :any, required: true
  attr :ships, :any, required: true
  attr :agent_id, :integer, required: true
  attr :form_drafts, :map, default: %{}
  attr :show_historical, :boolean, default: false

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
          <.negotiate_form ships={@ships} agent_id={@agent_id} form_drafts={@form_drafts} />
        </div>
      <% {:ok, contracts} -> %>
        <% historical_count = Enum.count(contracts, &Contracts.historical?/1) %>
        <button
          :if={historical_count > 0}
          id={"toggle-historical-contracts-#{@agent_id}"}
          type="button"
          phx-click="toggle_historical_contracts"
          phx-value-agent_id={@agent_id}
          class="btn btn-ghost btn-sm mb-3"
        >
          {if @show_historical, do: "Hide historical", else: "Show historical"} ({historical_count})
        </button>
        <details
          :for={contract <- visible_contracts(contracts, @show_historical)}
          id={contract_dom_id(contract)}
          data-contract-id={contract.id}
          data-contract-historical={Contracts.historical?(contract)}
          open={not Contracts.historical?(contract)}
          class="card border border-primary/30 bg-base-200 p-4 sm:p-5"
        >
          <summary class="cursor-pointer list-none">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <p class="eyebrow">Contract</p>
                <h3 class="mt-1 font-semibold">
                  {contract.type} <span class="font-mono text-xs opacity-60">{contract.id}</span>
                </h3>
                <%= if reward = contract_reward_label(contract) do %>
                  <p class="text-sm opacity-70">{reward}</p>
                <% end %>
                <p class="text-sm opacity-70">
                  Issued by <span class="font-mono">{contract.faction_symbol}</span>
                  <%= if deadline = contract_deadline_label(contract) do %>
                    <span class="opacity-50">·</span> {deadline}
                  <% end %>
                </p>
              </div>
              <span class="badge badge-outline">{contract_status(contract)}</span>
            </div>
          </summary>
          <div :for={good <- contract.terms.deliver || []} class="mt-4 space-y-2 text-sm">
            <% delivery_ships = delivery_ships(@ships, good.destination_symbol, good.trade_symbol) %>
            <div class="flex items-center justify-between">
              <span>{good.trade_symbol} to <span class="font-mono">{good.destination_symbol}</span></span>
              <span class="font-mono">{good.units_fulfilled} / {good.units_required}</span>
            </div>
            <form
              :for={ship <- delivery_ships}
              :if={contract.accepted && not Contracts.historical?(contract)}
              id={"deliver-form-#{contract.id}-#{ship.symbol}-#{good.trade_symbol}"}
              phx-change="track_draft"
              phx-submit="deliver_contract"
              class="grid grid-cols-[minmax(0,1fr)_5rem_auto] gap-2 sm:flex"
            >
              <input type="hidden" name="agent_id" value={@agent_id} />
              <input type="hidden" name="contract_id" value={contract.id} />
              <input type="hidden" name="trade_symbol" value={good.trade_symbol} />
              <input type="hidden" name="ship_symbol" value={ship.symbol} />
              <input
                type="hidden"
                name="draft_key"
                value={draft_key("deliver", [ship.symbol, contract.id, good.trade_symbol])}
              />
              <span class="self-center font-mono text-xs">
                {ship.symbol} ({delivery_units(ship, good.trade_symbol)} available)
              </span>
              <input
                name="units"
                type="number"
                min="1"
                max={delivery_limit(ship, good)}
                value={
                  draft_field(
                    @form_drafts,
                    "deliver",
                    [ship.symbol, contract.id, good.trade_symbol],
                    "units",
                    delivery_limit(ship, good)
                  )
                }
                class="input input-bordered input-sm w-full sm:w-20"
                required
              />
              <button type="submit" class="btn btn-secondary btn-sm">Deliver</button>
            </form>
            <p
              :if={contract.accepted && not Contracts.historical?(contract) && delivery_ships == []}
              class="text-xs opacity-70"
            >
              No ship at this waypoint has {good.trade_symbol} to deliver.
            </p>
          </div>
          <form
            :if={not contract.accepted && not Contracts.historical?(contract)}
            phx-submit="accept_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button
              type="submit"
              class="btn btn-primary min-h-11 btn-sm"
            >
              Accept contract
            </button>
          </form>
          <form
            :if={
              contract.accepted && not Contracts.historical?(contract) && Contracts.ready?(contract)
            }
            phx-submit="fulfill_contract"
            class="mt-4"
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="contract_id" value={contract.id} />
            <button type="submit" class="btn btn-primary min-h-11 btn-sm">Fulfill contract</button>
          </form>
        </details>
        <%= if Contracts.negotiable?(contracts) do %>
          <div class="card border border-primary/30 bg-base-200 p-4 sm:p-5">
            <p class="eyebrow">Mission briefing</p>
            <h3 class="mt-1 font-semibold">Negotiate a new contract</h3>
            <.negotiate_form ships={@ships} agent_id={@agent_id} form_drafts={@form_drafts} />
          </div>
        <% end %>
    <% end %>
    """
  end

  attr :ships, :any, required: true
  attr :agent_id, :integer, required: true
  attr :form_drafts, :map, default: %{}

  defp negotiate_form(assigns) do
    ~H"""
    <form
      id={"negotiate-form-#{@agent_id}"}
      phx-change="track_draft"
      phx-submit="negotiate_contract"
      class="mt-4"
    >
      <input type="hidden" name="agent_id" value={@agent_id} />
      <input type="hidden" name="draft_key" value={draft_key("negotiate", [@agent_id])} />
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
            <option
              :for={ship <- ships}
              value={ship.symbol}
              selected={
                draft_option_selected?(
                  @form_drafts,
                  "negotiate",
                  [@agent_id],
                  "ship_symbol",
                  ship.symbol
                )
              }
            >
              {ship.symbol} @ {ship_location(ship)}
            </option>
          </select>
        <% _ -> %>
          <input
            name="ship_symbol"
            value={draft_field(@form_drafts, "negotiate", [@agent_id], "ship_symbol", "")}
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
  attr :credits, :integer, default: nil

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
              data-ship-offer={ship.type}
              class="space-y-2 rounded border border-base-300/50 px-3 py-2"
            >
              <div class="flex flex-wrap items-center justify-between gap-3 text-sm">
                <div class="min-w-0">
                  <p class="font-semibold">{ship.name || ship.type}</p>
                  <p class="mt-1 text-xs opacity-70">
                    <span>Supply {supply_label(ship.supply)}</span>
                    <span class="mx-1 opacity-40">·</span>
                    <span>Speed {engine_speed(ship)}</span>
                    <span class="mx-1 opacity-40">·</span>
                    <span>Fuel {fuel_capacity(ship)}</span>
                    <span class="mx-1 opacity-40">·</span>
                    <span>Crew {crew_required(ship)}</span>
                  </p>
                </div>
                <form phx-submit="buy_ship" class="flex shrink-0 items-center gap-2">
                  <input type="hidden" name="agent_id" value={@agent_id} />
                  <input type="hidden" name="ship_type" value={ship.type} />
                  <input type="hidden" name="waypoint" value={listing.waypoint} />
                  <span class="font-mono">{credits_label(ship.purchase_price)} cr</span>
                  <button
                    type="submit"
                    disabled={unaffordable?(@credits, ship.purchase_price)}
                    class="btn btn-primary btn-xs"
                  >
                    Buy
                  </button>
                </form>
              </div>
              <details
                id={"ship-offer-specs-#{listing.waypoint}-#{ship.type}"}
                data-ship-offer-specs
                class="text-xs"
              >
                <summary class="cursor-pointer select-none font-semibold opacity-80">
                  Specifications
                </summary>
                <p :if={ship.description} class="mt-2 opacity-70">{ship.description}</p>
                <dl class="mt-2 space-y-1">
                  <.component_row label="Frame" item={ship.frame} metric={frame_metric(ship.frame)} />
                  <.component_row
                    label="Reactor"
                    item={ship.reactor}
                    metric={reactor_metric(ship.reactor)}
                  />
                  <.component_row
                    label="Engine"
                    item={ship.engine}
                    metric={engine_metric(ship.engine)}
                  />
                </dl>
                <.equipment_list label="Modules" items={ship.modules || []} />
                <.equipment_list label="Mounts" items={ship.mounts || []} />
              </details>
            </div>
          </div>
        </div>
      <% {:error, reason} -> %>
        <div class="alert alert-warning">{live_error(reason)}</div>
    <% end %>
    """
  end

  attr :label, :string, required: true
  attr :item, :map, default: nil
  attr :metric, :string, default: nil

  defp component_row(assigns) do
    ~H"""
    <div :if={@item} class="flex items-center justify-between gap-3">
      <dt class="opacity-60">{@label}</dt>
      <dd class="text-right">
        <span class="font-mono font-semibold">{@item.name}</span>
        <span :if={@metric} class="ml-2 opacity-70">{@metric}</span>
      </dd>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :items, :list, default: []

  defp equipment_list(assigns) do
    ~H"""
    <div :if={@items != []} class="mt-2">
      <p class="font-semibold uppercase tracking-wider opacity-60">{@label}</p>
      <ul class="mt-1 space-y-1">
        <li :for={item <- @items}>
          <span class="font-mono font-semibold">{item.name || item.symbol}</span>
          <span :if={equipment_metric(item)} class="ml-2 opacity-70">{equipment_metric(item)}</span>
        </li>
      </ul>
    </div>
    """
  end

  attr :listings, :any, required: true
  attr :agent_id, :integer, required: true
  attr :expanded_descriptions, :any, required: true
  attr :form_drafts, :map, default: %{}

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
              <% meta = good_meta(listing.market, good.symbol) %>
              <div class="flex items-center justify-between gap-3 text-sm">
                <div class="flex min-w-0 items-center gap-2">
                  <span class="font-mono font-semibold">{good.symbol}</span>
                  <span :if={meta.name} class="truncate opacity-70">{meta.name}</span>
                </div>
                <span class="font-mono">
                  Buy {credits_label(good.purchase_price)} cr <span class="opacity-50">·</span>
                  Sell {credits_label(good.sell_price)} cr
                </span>
              </div>
              <div class="flex flex-wrap items-center gap-1.5 text-xs">
                <span class="badge badge-outline badge-xs">{trade_role_label(good.type)}</span>
                <span class={supply_badge_class(good.supply)}>{good.supply}</span>
                <span :if={good.activity} class={activity_badge_class(good.activity)}>{good.activity}</span>
                <span class="opacity-70">Vol {good.trade_volume}</span>
                <button
                  :if={meta.description}
                  type="button"
                  phx-click="toggle_market_description"
                  phx-value-agent_id={@agent_id}
                  phx-value-waypoint={listing.waypoint}
                  phx-value-symbol={good.symbol}
                  aria-expanded={
                    to_string(
                      description_expanded?(
                        @expanded_descriptions,
                        @agent_id,
                        listing.waypoint,
                        good.symbol
                      )
                    )
                  }
                  aria-controls={"market-description-#{listing.waypoint}-#{good.symbol}"}
                  class="btn btn-ghost btn-xs px-2"
                >
                  {if description_expanded?(
                        @expanded_descriptions,
                        @agent_id,
                        listing.waypoint,
                        good.symbol
                      ),
                      do: "Hide description",
                      else: "Show description"}
                </button>
              </div>
              <p
                :if={
                  description_expanded?(
                    @expanded_descriptions,
                    @agent_id,
                    listing.waypoint,
                    good.symbol
                  )
                }
                id={"market-description-#{listing.waypoint}-#{good.symbol}"}
                class="text-sm opacity-70"
              >
                {meta.description}
              </p>
              <form
                :for={ship <- listing.ships}
                :if={sellable?(ship, good)}
                id={"sell-form-#{listing.waypoint}-#{ship.symbol}-#{good.symbol}"}
                phx-change="track_draft"
                phx-submit="sell_cargo"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="trade_symbol" value={good.symbol} />
                <input
                  type="hidden"
                  name="draft_key"
                  value={draft_key("sell", [ship.symbol, good.symbol])}
                />
                <span class="flex-1 text-xs opacity-70">
                  {ship.symbol}: {cargo_units(cargo_item(ship, good.symbol))} units
                </span>
                <input
                  type="number"
                  name="units"
                  min="1"
                  max={cargo_units(cargo_item(ship, good.symbol))}
                  value={
                    draft_field(
                      @form_drafts,
                      "sell",
                      [ship.symbol, good.symbol],
                      "units",
                      cargo_units(cargo_item(ship, good.symbol))
                    )
                  }
                  class="input input-bordered input-xs w-20"
                />
                <button type="submit" class="btn btn-secondary btn-xs">Sell</button>
              </form>
              <form
                :for={ship <- listing.ships}
                :if={buyable?(ship, good)}
                id={"buy-form-#{listing.waypoint}-#{ship.symbol}-#{good.symbol}"}
                phx-change="track_draft"
                phx-submit="purchase_cargo"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="trade_symbol" value={good.symbol} />
                <input
                  type="hidden"
                  name="draft_key"
                  value={draft_key("purchase", [ship.symbol, good.symbol])}
                />
                <span class="flex-1 text-xs opacity-70">{ship.symbol}</span>
                <input
                  type="number"
                  name="units"
                  min="1"
                  max={cargo_space(ship, good)}
                  value={
                    draft_field(
                      @form_drafts,
                      "purchase",
                      [ship.symbol, good.symbol],
                      "units",
                      "1"
                    )
                  }
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
  attr :waypoint_markets, :map, default: %{}
  attr :form_drafts, :map, default: %{}

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
                      data-transit-origin={route.origin.symbol}
                      data-transit-destination={route.destination.symbol}
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
                      data-orbital-offset-x={waypoint.orbital_offset_x}
                      data-orbital-offset-y={waypoint.orbital_offset_y}
                      data-orbital-distance={waypoint.orbital_distance}
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
                      market={Map.get(@waypoint_markets, {to_string(@agent_id), @selected_symbol})}
                      form_drafts={@form_drafts}
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
            market={Map.get(@waypoint_markets, {to_string(@agent_id), @selected_symbol})}
            form_drafts={@form_drafts}
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
  attr :market, :any, default: nil
  attr :form_drafts, :map, default: %{}

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
            <div :if={waypoint.type == "GAS_GIANT"} class="alert alert-info mt-4" data-siphon-location>
              <div>
                <p class="font-semibold">Gas giant: siphon location</p>
                <p class="text-sm">
                  Siphoning requires a ship in orbit with a gas siphon mount and gas processor.
                </p>
                <p class="text-sm opacity-75">
                  The waypoint API does not report which resource is available here.
                </p>
              </div>
            </div>
          </div>
          <div :if={waypoint_intelligence?(waypoint)} class="mt-4" data-waypoint-intelligence>
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">
              Waypoint Intelligence
            </p>
            <span
              :if={waypoint.is_under_construction == true}
              class="badge badge-warning badge-sm mt-2"
              data-construction-status
            >Under construction</span>
            <ul :if={(waypoint.modifiers || []) != []} class="mt-2 space-y-1">
              <li :for={modifier <- waypoint.modifiers || []}>
                <details
                  id={"modifier-#{@agent_id}-#{waypoint.symbol}-#{modifier.symbol}"}
                  data-modifier={modifier.symbol}
                >
                  <summary class="cursor-pointer text-sm">
                    <span class="badge badge-warning badge-outline badge-sm font-mono">
                      {modifier.symbol}
                    </span>
                    <span class="ml-2 opacity-70">{modifier.name}</span>
                  </summary>
                  <p class="mt-1 text-sm opacity-70">{modifier.description}</p>
                </details>
              </li>
            </ul>
          </div>
          <%= case @market do %>
            <% {:ok, market} -> %>
              <div class="mt-4" data-waypoint-market>
                <p class="text-xs font-semibold uppercase tracking-wider opacity-60">
                  Market Signals
                </p>
                <div class="mt-2 grid gap-3 sm:grid-cols-2">
                  <.market_goods label="Exports" goods={market.exports} />
                  <.market_goods label="Imports" goods={market.imports} />
                </div>
              </div>
            <% {:error, reason} -> %>
              <div class="alert alert-warning mt-4" data-waypoint-market>
                Market data unavailable: {live_error(reason)}
              </div>
            <% :not_a_marketplace -> %>
            <% _ -> %>
          <% end %>
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
          <details
            :if={waypoint_context?(waypoint)}
            id={"waypoint-context-#{@agent_id}-#{waypoint.symbol}"}
            class="mt-4"
            data-waypoint-context
          >
            <summary class="cursor-pointer text-xs font-semibold uppercase tracking-wider opacity-60">
              Context
            </summary>
            <dl class="mt-2 space-y-1 text-sm">
              <div :if={faction_symbol(waypoint)}>
                <dt class="text-xs opacity-60">Controlling faction</dt>
                <dd class="font-mono">{faction_symbol(waypoint)}</dd>
              </div>
              <div :if={chart_submitter(waypoint)}>
                <dt class="text-xs opacity-60">Chart submitter</dt>
                <dd class="font-mono">{chart_submitter(waypoint)}</dd>
              </div>
              <div :if={chart_submitted_label(waypoint)}>
                <dt class="text-xs opacity-60">Charted</dt>
                <dd class="font-mono">{chart_submitted_label(waypoint)}</dd>
              </div>
            </dl>
          </details>
          <form
            :if={browser_ships(@ships, waypoint.system_symbol) != []}
            id={"browser-navigate-#{waypoint.symbol}"}
            phx-change="track_draft"
            phx-submit="browser_navigate"
            class="mt-4"
          >
            <input
              type="hidden"
              name="draft_key"
              value={draft_key("browser_navigate", [waypoint.symbol])}
            /><label class="label py-1"><span class="label-text text-xs">Navigate a ship here</span></label><div class="flex gap-2">
              <select
                name="symbol"
                class="select select-bordered select-xs min-w-0 flex-1 font-mono"
                required
              ><option
                :for={ship <- browser_ships(@ships, waypoint.system_symbol)}
                value={ship.symbol}
                selected={
                  draft_option_selected?(
                    @form_drafts,
                    "browser_navigate",
                    [waypoint.symbol],
                    "symbol",
                    ship.symbol
                  )
                }
              >
                {ship.symbol}
              </option></select>
              <select
                name="waypoint_symbol"
                class="select select-bordered select-xs min-w-0 flex-1 font-mono"
              >
                <option
                  :for={
                    destination <- browser_navigation_destinations(@ships, waypoint, @form_drafts)
                  }
                  value={destination}
                  selected={
                    draft_field(
                      @form_drafts,
                      "browser_navigate",
                      [waypoint.symbol],
                      "waypoint_symbol",
                      waypoint.symbol
                    ) == destination
                  }
                >
                  {destination}
                </option>
              </select><button
                type="submit"
                class="btn btn-primary btn-xs"
              >Navigate</button>
            </div>
          </form>
      <% end %>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :goods, :list, default: []

  defp market_goods(assigns) do
    ~H"""
    <div>
      <p class="text-xs font-semibold uppercase tracking-wider opacity-60">{@label}</p>
      <div :if={@goods != []} class="mt-2 flex flex-wrap gap-1">
        <span :for={good <- @goods} class="badge badge-outline badge-sm font-mono" title={good.name}>
          {good.symbol}
        </span>
      </div>
      <p :if={@goods == []} class="mt-2 text-sm opacity-60">None reported</p>
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
  attr :form_drafts, :map, default: %{}
  attr :selected_ship, :string, default: nil

  defp fleet_grid(assigns) do
    ~H"""
    <div>
      <div class="mb-3 flex items-end justify-between">
        <div>
          <p class="eyebrow">Ship status</p>
          <h3 class="mt-1 text-lg font-semibold">Fleet</h3>
        </div>
        <div class="flex items-center gap-2 text-xs">
          <span data-fleet-roster>{fleet_count_label(@ships)}</span>
          <span
            :if={attention_count(@ships) > 0}
            class="badge badge-warning badge-sm"
            data-needs-attention-count
          >
            {attention_count(@ships)} needs attention
          </span>
          <span
            :if={fleet_healthy?(@ships)}
            class="badge badge-success badge-sm"
            data-fleet-healthy
          >
            Fleet healthy
          </span>
        </div>
      </div>

      <%= case @ships do %>
        <% {:ok, ships} -> %>
          <div :if={ships == []} class="alert alert-outline">
            This agent has no ships.
          </div>
          <div :if={ships != []} class="grid grid-cols-1 gap-4 xl:grid-cols-2">
            <.ship_card
              :for={ship <- ships}
              ship={ship}
              agent_id={@agent.id}
              cooldown_tick={@cooldown_tick}
              form_drafts={@form_drafts}
              selected={@selected_ship == ship.symbol}
              selected_mode={not is_nil(@selected_ship)}
            />
          </div>
        <% {:error, reason} -> %>
          <div class="alert alert-warning">{live_error(reason)}</div>
      <% end %>
    </div>
    """
  end

  attr :ship, :map, required: true
  attr :agent_id, :integer, required: true
  attr :cooldown_tick, :integer, default: 0
  attr :form_drafts, :map, default: %{}
  attr :selected, :boolean, default: false
  attr :selected_mode, :boolean, default: false

  defp ship_card(assigns) do
    ~H"""
    <div
      class={
        "card border border-base-300/70 bg-base-200 p-4 sm:p-5 " <>
          if(@selected, do: "ring-2 ring-primary ", else: "") <>
          if(@selected_mode and not @selected, do: "hidden", else: "")
      }
      data-ship-card={@ship.symbol}
      data-selected={to_string(@selected)}
    >
      <div class="flex items-center justify-between gap-2">
        <div class="flex items-center gap-2">
          <span class="font-mono font-semibold">{@ship.symbol}</span>
          <span class="badge badge-ghost badge-sm">{ship_role(@ship)}</span>
        </div>
        <span class={status_badge_class(@ship)}>{ship_status(@ship)}</span>
      </div>

      <button
        :if={not @selected}
        type="button"
        phx-click="select_ship"
        phx-value-agent_id={@agent_id}
        phx-value-symbol={@ship.symbol}
        class="btn btn-primary btn-sm mt-3 w-full"
        data-select-ship={@ship.symbol}
      >Open operations</button>

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
        <div class={operations_class(@selected)} data-ship-operations={@ship.symbol}>
          <div
            :for={item <- cargo_inventory(@ship)}
            data-cargo-item={item.symbol}
            class="mt-2 flex items-center justify-between gap-2 rounded border border-base-300/50 px-3 py-2 text-sm"
          >
            <div>
              <div class="flex flex-wrap items-baseline gap-2">
                <span class="font-mono font-semibold">{item.symbol}</span>
                <span :if={cargo_name(item)} class="opacity-70">{cargo_name(item)}</span>
                <span class="opacity-60">{item.units} units</span>
              </div>
              <details
                :if={cargo_description(item)}
                id={"cargo-description-#{@ship.symbol}-#{item.symbol}"}
                class="mt-1"
                data-cargo-description={item.symbol}
              >
                <summary class="cursor-pointer text-xs opacity-70">Description</summary>
                <p class="mt-1 text-xs opacity-70">{cargo_description(item)}</p>
              </details>
            </div>
            <form
              id={"jettison-form-#{@ship.symbol}-#{item.symbol}"}
              phx-change="track_draft"
              phx-submit="jettison_cargo"
              class="flex items-center gap-2"
            >
              <input type="hidden" name="symbol" value={@ship.symbol} />
              <input type="hidden" name="trade_symbol" value={item.symbol} />
              <input
                type="hidden"
                name="draft_key"
                value={draft_key("jettison", [@ship.symbol, item.symbol])}
              />
              <input
                type="number"
                name="units"
                min="1"
                max={item.units}
                value={
                  draft_field(
                    @form_drafts,
                    "jettison",
                    [@ship.symbol, item.symbol],
                    "units",
                    item.units
                  )
                }
                class="input input-bordered input-xs w-16"
              />
              <button type="submit" class="btn btn-ghost btn-xs">Jettison</button>
            </form>
          </div>
        </div>
      </div>

      <div class={"mt-4 #{operations_class(@selected)}"} data-ship-operations={@ship.symbol}>
        <div
          :if={@selected}
          class="mb-3 flex items-center justify-between rounded bg-base-300/40 px-3 py-2 text-xs"
        >
          <span class="font-semibold">Selected Ship operations</span>
          <button
            type="button"
            phx-click="clear_ship"
            phx-value-agent_id={@agent_id}
            class="btn btn-ghost btn-xs"
            data-back-to-fleet
          >Back to Fleet</button>
        </div>
        <.autopilot_panel ship={@ship} form_drafts={@form_drafts} />

        <%= if in_transit?(@ship) do %>
          <div class="flex flex-wrap items-center gap-2 text-xs">
            <span class="badge badge-warning badge-sm">In transit</span>
            <span class="font-mono" data-transit-arrival>{arrival_label(@ship)}</span>
          </div>
          <p class="mt-1 text-xs opacity-60" data-transit-route-summary>
            From <span class="font-mono">{route_origin(@ship)}</span>
            to <span class="font-mono">{route_destination(@ship)}</span>.
            Actions resume when the ship arrives.
          </p>
          <details id={"route-details-#{@ship.symbol}"} class="mt-2" data-route-details>
            <summary class="cursor-pointer text-xs opacity-70">Route details</summary>
            <dl class="mt-2 space-y-1 text-xs">
              <div class="flex items-center justify-between gap-3">
                <dt class="opacity-60">Departure</dt>
                <dd class="font-mono">{departure_label(@ship)}</dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt class="opacity-60">Origin</dt>
                <dd class="font-mono">{route_origin(@ship)}</dd>
              </div>
              <div class="flex items-center justify-between gap-3">
                <dt class="opacity-60">Destination</dt>
                <dd class="font-mono">{route_destination(@ship)}</dd>
              </div>
            </dl>
          </details>
        <% else %>
          <form
            id={"navigate-form-#{@ship.symbol}"}
            phx-change="track_draft"
            phx-submit="navigate"
            phx-value-symbol={@ship.symbol}
            class="flex gap-2"
          >
            <input
              type="hidden"
              name="draft_key"
              value={draft_key("navigate", [@ship.symbol])}
            />
            <input
              type="text"
              name="waypoint_symbol"
              value={draft_field(@form_drafts, "navigate", [@ship.symbol], "waypoint_symbol", "")}
              placeholder="Waypoint symbol"
              autocomplete="off"
              list={
                if destination_history(@ship) == [],
                  do: nil,
                  else: "destination-history-#{@ship.symbol}"
              }
              class="input input-sm input-bordered min-h-11 flex-1 font-mono"
            />
            <datalist
              :if={destination_history(@ship) != []}
              id={"destination-history-#{@ship.symbol}"}
            >
              <option :for={destination <- destination_history(@ship)} value={destination} />
            </datalist>
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
              phx-click="siphon"
              phx-value-symbol={@ship.symbol}
              disabled={not siphonable?(@ship)}
              class="btn btn-ghost min-h-10 btn-sm"
            >
              Siphon
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

      <details
        id={"ship-readiness-#{@ship.symbol}"}
        class={"mt-4 border-t border-base-300/60 pt-3 #{operations_class(@selected)}"}
        data-ship-readiness
      >
        <summary class="cursor-pointer text-sm font-semibold">Ship Readiness</summary>
        <div class="mt-3 space-y-4 text-sm">
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div>
              <div class="text-xs opacity-60">Flight Mode</div>
              <div class="font-mono">{flight_mode(@ship)}</div>
            </div>
            <div>
              <div class="text-xs opacity-60">Crew</div>
              <div class="font-mono">{crew_label(@ship)}</div>
              <div class="text-xs opacity-60">current / required / capacity</div>
              <div :if={crew_morale(@ship)} class="text-xs opacity-60">
                Morale {crew_morale(@ship)}
              </div>
            </div>
            <div>
              <div class="text-xs opacity-60">Engine</div>
              <div class="font-semibold">{component_name(@ship.engine)}</div>
              <div class="font-mono">{engine_speed_label(@ship)}</div>
            </div>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Components</p>
            <div class="mt-2 space-y-2">
              <div
                :for={{kind, component} <- ship_components(@ship)}
                data-component={String.downcase(kind)}
                class="rounded border border-base-300/50 px-3 py-2"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="text-xs uppercase tracking-wider opacity-60">{kind}</span>
                  <span class="font-semibold">{component_name(component)}</span>
                  <span class="font-mono">Condition {component_condition(component)}</span>
                </div>
                <details
                  id={"component-detail-#{@ship.symbol}-#{String.downcase(kind)}"}
                  class="mt-1"
                  data-component-detail={String.downcase(kind)}
                >
                  <summary class="cursor-pointer text-xs opacity-70">Detail</summary>
                  <dl class="mt-2 space-y-1 text-xs">
                    <div class="flex items-center justify-between gap-3">
                      <dt class="opacity-60">Integrity</dt>
                      <dd class="font-mono">{component_integrity(component)}</dd>
                    </div>
                    <div
                      :if={component_quality(component)}
                      class="flex items-center justify-between gap-3"
                    >
                      <dt class="opacity-60">Quality</dt>
                      <dd class="font-mono">{component_quality(component)}</dd>
                    </div>
                    <p :if={component_description(component)} class="pt-1 opacity-70">
                      {component_description(component)}
                    </p>
                  </dl>
                </details>
              </div>
            </div>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Modules</p>
            <div :if={@ship.modules == []} class="mt-1 text-xs opacity-60">
              No modules installed.
            </div>
            <div :for={module <- @ship.modules || []} class="mt-1 space-y-2">
              <div data-module={module.symbol} class="rounded border border-base-300/50 px-3 py-2">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="font-semibold">{module.name}</span>
                  <span class="flex flex-wrap gap-3 font-mono text-xs opacity-70">
                    <span :if={module_capacity(module)}>capacity {module_capacity(module)}</span>
                    <span :if={module_range(module)}>range {module_range(module)}</span>
                  </span>
                </div>
                <details
                  :if={equipment_description(module)}
                  id={"module-description-#{@ship.symbol}-#{module.symbol}"}
                  class="mt-1"
                  data-equipment-description
                >
                  <summary class="cursor-pointer text-xs opacity-70">Description</summary>
                  <p class="mt-1 text-xs opacity-70">{equipment_description(module)}</p>
                </details>
              </div>
            </div>
          </div>

          <div class="rounded border border-info/30 bg-info/5 px-3 py-2 text-xs" data-siphon-readiness>
            <p class="font-semibold">Siphon readiness</p>
            <p class="mt-1">
              Requires orbit, a mount named <span class="font-mono">MOUNT_GAS_SIPHON_*</span>, and <span class="font-mono">MODULE_GAS_PROCESSOR_I</span>.
            </p>
            <p class="mt-1 opacity-70">
              The dashboard does not currently purchase or outfit these components.
            </p>
          </div>

          <div>
            <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Mounts</p>
            <div :if={@ship.mounts == []} class="mt-1 text-xs opacity-60">No mounts installed.</div>
            <div :for={mount <- @ship.mounts || []} class="mt-1 space-y-2">
              <div data-mount={mount.symbol} class="rounded border border-base-300/50 px-3 py-2">
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="font-semibold">{mount.name}</span>
                  <span class="flex flex-wrap gap-3 font-mono text-xs opacity-70">
                    <span :if={mount_strength(mount)}>strength {mount_strength(mount)}</span>
                    <span :if={mount_deposits(mount) != []}>{Enum.join(mount_deposits(mount), ", ")}</span>
                  </span>
                </div>
                <details
                  :if={equipment_description(mount)}
                  id={"mount-description-#{@ship.symbol}-#{mount.symbol}"}
                  class="mt-1"
                  data-equipment-description
                >
                  <summary class="cursor-pointer text-xs opacity-70">Description</summary>
                  <p class="mt-1 text-xs opacity-70">{equipment_description(mount)}</p>
                </details>
              </div>
            </div>
          </div>
        </div>
      </details>
    </div>
    """
  end

  attr :ship, :map, required: true
  attr :form_drafts, :map, default: %{}

  defp autopilot_panel(assigns) do
    config = Map.get(assigns.ship, :autopilot)
    assigns = assign(assigns, :autopilot, config)

    ~H"""
    <div class="mt-4 rounded border border-primary/20 p-3" data-autopilot-panel>
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">Autopilot</span>
        <span class="badge badge-outline badge-sm" data-autopilot-status>
          {autopilot_status(@autopilot)}
        </span>
      </div>
      <dl class="mt-3 grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
        <div>
          <dt class="opacity-60">Current action</dt>
          <dd data-autopilot-current-action>{autopilot_current_action(@autopilot, @ship)}</dd>
        </div>
        <div>
          <dt class="opacity-60">Next action</dt>
          <dd data-autopilot-next-action>{autopilot_next_action(@autopilot, @ship)}</dd>
        </div>
      </dl>
      <p :if={autopilot_reason(@autopilot)} class="mt-2 text-xs text-error" data-autopilot-reason>
        {autopilot_reason(@autopilot)}
      </p>
      <form
        id={"autopilot-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit="configure_autopilot"
        class="mt-3 grid gap-2 sm:grid-cols-3"
      >
        <input type="hidden" name="draft_key" value={draft_key("autopilot", [@ship.symbol])} />
        <input type="hidden" name="ship_symbol" value={@ship.symbol} />
        <input
          name="extraction_waypoint"
          value={
            draft_field(
              @form_drafts,
              "autopilot",
              [@ship.symbol],
              "extraction_waypoint",
              @autopilot && @autopilot.extraction_waypoint
            )
          }
          placeholder="Extraction waypoint"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="market_waypoint"
          value={
            draft_field(
              @form_drafts,
              "autopilot",
              [@ship.symbol],
              "market_waypoint",
              @autopilot && @autopilot.market_waypoint
            )
          }
          placeholder="Market waypoint"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="cargo_threshold"
          value={
            draft_field(
              @form_drafts,
              "autopilot",
              [@ship.symbol],
              "cargo_threshold",
              @autopilot && @autopilot.cargo_threshold
            )
          }
          type="number"
          min="1"
          placeholder="Cargo threshold"
          class="input input-bordered input-sm"
          required
        />
        <button type="submit" class="btn btn-ghost btn-sm sm:col-span-3">Save loop configuration</button>
      </form>
      <div class="mt-2 flex flex-wrap gap-2">
        <button
          :if={
            is_nil(@autopilot) or
              (@autopilot.desired_mode == "manual" and @autopilot.status not in ["paused", "blocked"])
          }
          type="button"
          phx-click="start_autopilot"
          phx-value-symbol={@ship.symbol}
          data-confirm="Start Autopilot for this Ship?"
          class="btn btn-primary btn-sm"
        >
          Start Autopilot
        </button>
        <button
          :if={@autopilot && @autopilot.desired_mode == "autopilot"}
          type="button"
          phx-click="pause_autopilot"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-sm"
        >
          Pause
        </button>
        <button
          :if={@autopilot && @autopilot.status in ["paused", "blocked"]}
          type="button"
          phx-click="resume_autopilot"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >
          Resume after revalidation
        </button>
        <button
          :if={@autopilot}
          type="button"
          phx-click="stop_autopilot"
          phx-value-symbol={@ship.symbol}
          data-confirm="Stop Autopilot and clear this configuration?"
          class="btn btn-ghost btn-sm"
        >
          Stop to Manual
        </button>
      </div>
    </div>
    """
  end

  defp activity_panel(assigns) do
    activities =
      assigns.overviews
      |> Enum.flat_map(fn %{activity: activity} -> activity end)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.take(10)
      |> Enum.sort_by(& &1.inserted_at, DateTime)

    assigns = assign(assigns, :activities, activities)

    ~H"""
    <section class="card border border-base-300/70 bg-base-200 p-4" data-activity>
      <div class="flex items-center justify-between">
        <div>
          <p class="eyebrow">Activity</p>
          <h3 class="mt-1 text-lg font-semibold">Recent Fleet events</h3>
        </div>
        <span class="text-xs opacity-60">Latest 10 · chronological</span>
      </div>
      <div :if={@activities == []} class="mt-3 text-sm opacity-60">No local recovery events yet.</div>
      <ol :if={@activities != []} class="mt-3 space-y-2 text-sm">
        <li
          :for={event <- @activities}
          class="flex flex-wrap justify-between gap-2 border-t border-base-300/50 pt-2"
        >
          <span class="min-w-0">
            <strong>{event.kind}</strong>
            <span :if={event.ship}> · <span class="font-mono">{event.ship.symbol}</span></span>
            <span>{event.message}</span>
            <span
              :for={{label, value} <- activity_facts(event)}
              class="badge badge-outline badge-xs ml-1"
            >
              {label}: {value}
            </span>
          </span>
          <time class="text-xs opacity-60">{Calendar.strftime(event.inserted_at, "%Y-%m-%d %H:%M:%S")}</time>
        </li>
      </ol>
    </section>
    """
  end

  defp autopilot_status(%{status: "blocked"}), do: "Blocked"
  defp autopilot_status(%{status: "paused"}), do: "Paused by manual action"
  defp autopilot_status(nil), do: "Manual"
  defp autopilot_status(%{desired_mode: "autopilot", status: "waiting"}), do: "Waiting"
  defp autopilot_status(%{desired_mode: "autopilot"}), do: "Active Autopilot"
  defp autopilot_status(_), do: "Manual"

  defp autopilot_reason(%{status: "blocked", blocked_reason: reason}) when is_binary(reason),
    do: "Blocked: #{reason}"

  defp autopilot_reason(%{status: "paused", blocked_reason: reason}) when is_binary(reason),
    do: reason

  defp autopilot_reason(_), do: nil

  defp autopilot_current_action(
         %{status: "waiting", in_flight_action: %{"kind" => "extract"}},
         _ship
       ),
       do: "Waiting for cooldown"

  defp autopilot_current_action(
         %{status: "waiting", in_flight_action: %{"kind" => "navigate"}},
         _ship
       ),
       do: "Traveling to configured waypoint"

  defp autopilot_current_action(
         %{status: "waiting", in_flight_action: %{"kind" => "cooldown"}},
         _ship
       ),
       do: "Waiting for cooldown"

  defp autopilot_current_action(%{status: "blocked"}, _ship), do: "Blocked"
  defp autopilot_current_action(%{status: "paused"}, _ship), do: "Paused by manual action"
  defp autopilot_current_action(%{desired_mode: "autopilot"}, _ship), do: "Evaluating cargo"
  defp autopilot_current_action(_, _ship), do: "Manual"

  defp autopilot_next_action(
         %{status: "waiting", in_flight_action: %{"kind" => "navigate", "waypoint" => waypoint}},
         _ship
       ),
       do: "Continue at #{waypoint}"

  defp autopilot_next_action(%{status: "waiting"}, ship) do
    case cooldown_label(ship, 0) do
      "Ready" -> "Reconcile ship"
      label -> "Wait through #{label}"
    end
  end

  defp autopilot_next_action(%{status: "blocked"}, _ship), do: "Resolve the issue, then Resume"
  defp autopilot_next_action(%{status: "paused"}, _ship), do: "Resume after revalidation"

  defp autopilot_next_action(%{desired_mode: "autopilot", extraction_waypoint: waypoint}, ship) do
    if cooldown_active?(ship),
      do: "Wait through #{cooldown_label(ship, 0)}",
      else: "Evaluate at #{waypoint}"
  end

  defp autopilot_next_action(_, _ship), do: "Start Autopilot"

  defp attention_count({:ok, ships}), do: Enum.count(ships, &needs_attention?/1)
  defp attention_count(_), do: 0

  defp fleet_healthy?({:ok, ships}), do: ships != [] and attention_count({:ok, ships}) == 0
  defp fleet_healthy?(_), do: false

  defp operations_class(true), do: ""
  defp operations_class(false), do: "hidden"

  defp needs_attention?(%{autopilot: %{status: "blocked"}}), do: true
  defp needs_attention?(%{autopilot: %{status: "paused"}}), do: true
  defp needs_attention?(%{nav: %{status: "IN_TRANSIT"}}), do: false
  defp needs_attention?(_), do: false

  defp activity_facts(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Enum.filter(fn {key, _value} ->
      key in ["outcome", "delta", "wait", "retry", "block", "recovery"]
    end)
    |> Enum.map(fn {key, value} -> {key, format_activity_value(value)} end)
  end

  defp activity_facts(_), do: []

  defp format_activity_value(value) when is_binary(value), do: value
  defp format_activity_value(value), do: inspect(value)

  ## Display helpers

  defp active_contract?(%{contracts: {:ok, contracts}}),
    do: Enum.any?(contracts, &Contracts.active?/1)

  defp active_contract?(_), do: false

  defp contract_status(contract), do: contract_status_label(Contracts.status(contract))

  defp contract_status_label(:fulfilled), do: "FULFILLED"
  defp contract_status_label(:expired), do: "EXPIRED"
  defp contract_status_label(:accepted), do: "ACCEPTED"
  defp contract_status_label(:pending), do: "PENDING"

  defp contract_reward_label(%{
         terms: %{payment: %{on_accepted: on_accepted, on_fulfilled: on_fulfilled}}
       })
       when is_integer(on_accepted) and is_integer(on_fulfilled) do
    "Reward: #{credits_label(on_accepted)} cr on acceptance, " <>
      "#{credits_label(on_fulfilled)} cr on fulfillment"
  end

  defp contract_reward_label(_), do: nil

  defp contract_deadline_label(%{fulfilled: true}), do: nil

  defp contract_deadline_label(contract) do
    case Contracts.deadline(contract) do
      {:completion, deadline} when is_binary(deadline) ->
        format_contract_deadline(deadline, "Complete by")

      {:acceptance, deadline} when is_binary(deadline) ->
        format_contract_deadline(deadline, "Accept by")

      _ ->
        nil
    end
  end

  defp format_contract_deadline(deadline, prefix) do
    case DateTime.from_iso8601(deadline) do
      {:ok, date_time, _offset} ->
        "#{prefix} #{Calendar.strftime(date_time, "%m-%d %H:%M UTC")}"

      _ ->
        nil
    end
  end

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

  defp live_credits({:ok, live}) when is_map(live), do: Map.get(live, :credits)
  defp live_credits(_), do: nil

  defp unaffordable?(credits, price) when is_integer(credits) and is_integer(price),
    do: credits < price

  defp unaffordable?(_, _), do: false

  defp supply_label(nil), do: "—"
  defp supply_label(supply) when is_binary(supply), do: supply

  defp engine_speed(%{engine: %{speed: speed}}) when is_integer(speed), do: speed
  defp engine_speed(_), do: "—"

  defp fuel_capacity(%{frame: %{fuel_capacity: fuel}}) when is_integer(fuel), do: fuel
  defp fuel_capacity(_), do: "—"

  defp crew_required(%{crew: %{required: required}}) when is_integer(required), do: required
  defp crew_required(_), do: "—"

  defp frame_metric(%{fuel_capacity: fuel, module_slots: slots, mounting_points: points})
       when is_integer(fuel) and is_integer(slots) and is_integer(points),
       do: "#{fuel} fuel, #{slots} slots, #{points} mounts"

  defp frame_metric(%{fuel_capacity: fuel}) when is_integer(fuel), do: "#{fuel} fuel"

  defp frame_metric(%{module_slots: slots, mounting_points: points})
       when is_integer(slots) and is_integer(points),
       do: "#{slots} slots, #{points} mounts"

  defp frame_metric(_), do: nil

  defp reactor_metric(%{power_output: power}) when is_integer(power), do: "#{power} power"
  defp reactor_metric(_), do: nil

  defp engine_metric(%{speed: speed}) when is_integer(speed), do: "speed #{speed}"
  defp engine_metric(_), do: nil

  defp equipment_metric(%{capacity: capacity}) when is_integer(capacity),
    do: "capacity #{capacity}"

  defp equipment_metric(%{range: range}) when is_integer(range), do: "range #{range}"

  defp equipment_metric(%{strength: strength}) when is_integer(strength),
    do: "strength #{strength}"

  defp equipment_metric(%{deposits: deposits}) when is_list(deposits) and deposits != [],
    do: Enum.join(deposits, ", ")

  defp equipment_metric(_), do: nil

  defp live_error(:ship_in_transit), do: "This ship is in transit; actions resume on arrival."
  defp live_error(:cooldown_active), do: "This ship is on cooldown; wait for it to end."
  defp live_error(:agent_token_missing), do: "No AgentToken stored for this agent."

  defp live_error(:insufficient_credits),
    do: "The agent does not have enough credits for that ship."

  defp live_error(:shipyard_unavailable), do: "That shipyard is not available."
  defp live_error(:market_unavailable), do: "That market is not available."

  defp live_error(:invalid_extraction_waypoint),
    do: "Choose an ASTEROID_FIELD or ENGINEERED_ASTEROID extraction waypoint."

  defp live_error(:invalid_market_waypoint), do: "Choose a waypoint with a MARKETPLACE trait."

  defp live_error(:cargo_threshold_exceeds_capacity),
    do: "Cargo threshold exceeds this Ship's capacity."

  defp live_error(:mining_capability_missing), do: "This Ship has no mining laser installed."

  defp live_error(:siphon_capability_missing),
    do: "This Ship needs a gas siphon mount and gas processor."

  defp live_error(:invalid_siphon_waypoint),
    do: "Siphoning requires a Ship in orbit around a gas giant."

  defp live_error(:ship_not_owned), do: "That Ship is not in this agent's Fleet."
  defp live_error(:autopilot_not_configured), do: "Save an Autopilot configuration first."
  defp live_error({:autopilot_blocked, reason}), do: "Autopilot blocked: #{live_error(reason)}"
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

  defp siphonable?(ship),
    do: not cooldown_active?(ship) and ship_status(ship) == "IN_ORBIT" and siphon_equipped?(ship)

  defp refuelable?(ship), do: not cooldown_active?(ship) and ship_status(ship) == "DOCKED"

  defp siphon_equipped?(ship) do
    Enum.any?(ship.mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_GAS_SIPHON_")) and
      Enum.any?(ship.modules || [], &(&1.symbol == "MODULE_GAS_PROCESSOR_I"))
  end

  defp arrival_label(%{nav: %{route: %{arrival: arrival}}}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} -> "arrives #{Calendar.strftime(due_at, "%m-%d %H:%M")} UTC"
      _ -> "arrives soon"
    end
  end

  defp arrival_label(_), do: "arrives soon"

  defp flight_mode(%{nav: %{flight_mode: mode}}) when is_binary(mode), do: mode
  defp flight_mode(_), do: "—"

  defp crew_label(%{crew: %{current: current, required: required, capacity: capacity}})
       when is_integer(current) and is_integer(required) and is_integer(capacity),
       do: "#{current} / #{required} / #{capacity}"

  defp crew_label(_), do: "—"

  defp crew_morale(%{crew: %{morale: morale}}) when is_integer(morale), do: morale
  defp crew_morale(_), do: nil

  defp engine_speed_label(%{engine: %{speed: speed}}) when is_integer(speed), do: "speed #{speed}"
  defp engine_speed_label(_), do: "speed —"

  defp ship_components(ship) do
    [{"Frame", ship.frame}, {"Reactor", ship.reactor}, {"Engine", ship.engine}]
    |> Enum.filter(fn {_kind, component} -> not is_nil(component) end)
  end

  defp component_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp component_name(%{symbol: symbol}) when is_binary(symbol), do: symbol
  defp component_name(_), do: "—"

  defp component_condition(%{condition: condition}) when is_number(condition), do: condition
  defp component_condition(_), do: "—"

  defp component_integrity(%{integrity: integrity}) when is_number(integrity), do: integrity
  defp component_integrity(_), do: "—"

  defp component_quality(%{quality: quality}) when is_number(quality), do: quality
  defp component_quality(_), do: nil

  defp component_description(%{description: description})
       when is_binary(description) and description != "",
       do: description

  defp component_description(_), do: nil

  defp module_capacity(%{capacity: capacity}) when is_integer(capacity), do: capacity
  defp module_capacity(_), do: nil

  defp module_range(%{range: range}) when is_integer(range), do: range
  defp module_range(_), do: nil

  defp mount_strength(%{strength: strength}) when is_integer(strength), do: strength
  defp mount_strength(_), do: nil

  defp mount_deposits(%{deposits: deposits}) when is_list(deposits), do: deposits
  defp mount_deposits(_), do: []

  defp equipment_description(%{description: description})
       when is_binary(description) and description != "",
       do: description

  defp equipment_description(_), do: nil

  defp route_origin(%{nav: %{route: %{origin: %{symbol: origin}}}}) when is_binary(origin),
    do: origin

  defp route_origin(_), do: "—"

  defp route_destination(%{nav: %{route: %{destination: %{symbol: destination}}}})
       when is_binary(destination),
       do: destination

  defp route_destination(_), do: "—"

  defp departure_label(%{nav: %{route: %{departure_time: departure}}})
       when is_binary(departure) do
    case DateTime.from_iso8601(departure) do
      {:ok, date_time, _offset} -> Calendar.strftime(date_time, "%m-%d %H:%M") <> " UTC"
      _ -> "unknown"
    end
  end

  defp departure_label(_), do: "unknown"

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

  defp cargo_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp cargo_name(_), do: nil

  defp cargo_description(%{description: description})
       when is_binary(description) and description != "",
       do: description

  defp cargo_description(_), do: nil

  defp sellable?(ship, good), do: cargo_item(ship, good.symbol) != nil

  defp buyable?(ship, good) do
    (good.purchase_price || 0) > 0 and cargo_space(ship, good) > 0
  end

  @caution_supply ["SCARCE", "LIMITED"]
  @caution_activity ["RESTRICTED"]

  defp good_meta(market, symbol) do
    good_catalog(market) |> Map.get(symbol, %{name: nil, description: nil})
  end

  defp good_catalog(market) do
    Enum.reduce([market.exports, market.imports, market.exchange], %{}, fn goods, catalog ->
      Enum.reduce(goods || [], catalog, fn good, catalog ->
        Map.put_new(catalog, good.symbol, %{
          name: good.name,
          description: good.description
        })
      end)
    end)
  end

  defp trade_role_label(nil), do: "—"

  defp trade_role_label(role) when is_binary(role) do
    role |> String.downcase() |> String.capitalize()
  end

  defp supply_badge_class(supply) when supply in @caution_supply,
    do: "badge badge-warning badge-xs"

  defp supply_badge_class(_), do: "badge badge-outline badge-xs"

  defp activity_badge_class(activity) when activity in @caution_activity,
    do: "badge badge-warning badge-xs"

  defp activity_badge_class(_), do: "badge badge-outline badge-xs"

  defp description_expanded?(expanded, agent_id, waypoint, symbol) do
    MapSet.member?(expanded, {to_string(agent_id), waypoint, symbol})
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

  defp destination_history(%{destination_history: history}) when is_list(history), do: history
  defp destination_history(_), do: []

  defp browser_navigation_destinations(ships, waypoint, drafts) do
    available_ships = browser_ships(ships, waypoint.system_symbol)
    selected_ship = draft_field(drafts, "browser_navigate", [waypoint.symbol], "symbol", nil)

    ship =
      Enum.find(available_ships, &(&1.symbol == selected_ship)) || List.first(available_ships)

    [waypoint.symbol | destination_history(ship)]
    |> Enum.uniq()
  end

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

  defp waypoint_intelligence?(%{is_under_construction: true}), do: true

  defp waypoint_intelligence?(%{modifiers: modifiers})
       when is_list(modifiers) and modifiers != [],
       do: true

  defp waypoint_intelligence?(_waypoint), do: false

  defp waypoint_context?(waypoint) do
    faction_symbol(waypoint) != nil or chart_submitter(waypoint) != nil or
      chart_submitted_label(waypoint) != nil
  end

  defp faction_symbol(%{faction: %{symbol: symbol}}) when is_binary(symbol), do: symbol
  defp faction_symbol(_waypoint), do: nil

  defp chart_submitter(%{chart: %{submitted_by: submitted_by}}) when is_binary(submitted_by),
    do: submitted_by

  defp chart_submitter(_waypoint), do: nil

  defp chart_submitted_label(%{chart: %{submitted_on: submitted_on}})
       when is_binary(submitted_on) do
    case DateTime.from_iso8601(submitted_on) do
      {:ok, date_time, _offset} -> Calendar.strftime(date_time, "%m-%d %H:%M UTC")
      _ -> nil
    end
  end

  defp chart_submitted_label(_waypoint), do: nil

  defp selected_waypoint_class(%{symbol: symbol}, symbol), do: "selected"
  defp selected_waypoint_class(_, _), do: ""

  defp filtered_waypoint_class(waypoint, filtered_set) do
    if MapSet.member?(filtered_set, waypoint.symbol), do: "", else: "muted"
  end

  defp capacity(nil), do: 0
  defp capacity(%{capacity: capacity}) when is_integer(capacity), do: capacity
  defp capacity(_), do: 0
end
