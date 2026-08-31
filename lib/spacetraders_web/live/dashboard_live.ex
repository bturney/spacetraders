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
  alias SpaceTraders.Fleet.Job
  alias SpaceTraders.Fleet.JobBlocker
  alias SpaceTraders.Intelligence
  alias SpaceTraders.SystemWaypointProjection
  alias SpaceTradersWeb.DashboardPrototype

  @gather_kinds ["extract", "siphon"]

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

            <.stale_agent_card stale_agents={stale_agents(@overviews)} />

            <.contract_hero overviews={non_stale_overviews(@overviews)} />

            <div :if={@overviews == []} class="alert alert-outline">
              You haven't minted any agents yet.
              <.link navigate={~p"/agents/new"} class="font-semibold underline">
                Mint your first agent
              </.link>
              .
            </div>

            <.agent_section
              :for={overview <- @overviews}
              :if={not overview.stale?}
              overview={overview}
              cooldown_tick={@cooldown_tick}
              form_drafts={@form_drafts}
              selected_waypoints={@selected_waypoints}
              waypoint_filters={@waypoint_filters}
              expanded_market_descriptions={@expanded_market_descriptions}
              show_historical_contracts={@show_historical_contracts}
              waypoint_markets={@waypoint_markets}
              waypoint_intelligence={@waypoint_intelligence}
              selected_ships={@selected_ships}
              jump_previews={@jump_previews}
            />

            <.activity_panel overviews={non_stale_overviews(@overviews)} />
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

  defp non_stale_overviews(overviews), do: Enum.reject(overviews, & &1.stale?)

  defp stale_agents(overviews) do
    for %{stale?: true, agent: agent} <- overviews, do: agent
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
       form_drafts: %{},
       expanded_market_descriptions: MapSet.new(),
       show_historical_contracts: MapSet.new(),
       selected_waypoints: %{},
       selected_ships: %{},
       jump_previews: %{},
       waypoint_filters: %{},
       waypoint_markets: %{},
       waypoint_intelligence: %{}
     )}
  end

  @impl true
  def handle_event("retire_stale_agents", _params, socket) do
    case Agent.retire_stale_agents(socket.assigns.current_scope.operator) do
      {:ok, []} ->
        {:noreply, put_flash(socket, :info, "There are no stale Agents to retire.")}

      {:ok, retired_symbols} ->
        {:noreply,
         socket
         |> assign(:overviews, non_stale_overviews(socket.assigns.overviews))
         |> put_flash(:info, "Retired stale Agents: #{Enum.join(retired_symbols, ", ")}.")}
    end
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
      result =
        if params["confirm_jump"] == "true" do
          Fleet.confirm_jump_intent(agent, ship_symbol, waypoint, params)
        else
          case Fleet.jump_preview(agent, ship_symbol, waypoint) do
            {:ok, preview} -> {:preview, preview}
            {:error, :same_system_route} -> Fleet.navigate_intent(agent, ship_symbol, waypoint)
            {:error, reason} -> Fleet.block_jump_preview(agent, ship_symbol, waypoint, reason)
          end
        end

      case result do
        {:preview, preview} ->
          {:noreply,
           socket
           |> assign(:jump_previews, Map.put(socket.assigns.jump_previews, ship_symbol, preview))
           |> put_flash(:info, "Review the jump route before dispatching it.")}

        {:ok, %{status: "completed", target_waypoint: target}} ->
          {:noreply,
           put_flash(
             socket |> refresh_agent_fleet(agent.id) |> clear_draft(drafted_key),
             :info,
             "#{ship_symbol} is already at #{target}."
           )}

        {:ok, %{status: "waiting", target_waypoint: target} = intent} ->
          message =
            if match?(%{"wait" => "cooldown"}, intent.last_action_result) do
              "#{ship_symbol} will navigate to #{target} once its cooldown ends."
            else
              "#{ship_symbol} is in transit to #{target}."
            end

          {:noreply,
           put_flash(
             socket |> refresh_agent_fleet(agent.id) |> clear_draft(drafted_key),
             :info,
             message
           )}

        {:ok, %{status: "active", target_waypoint: target}} ->
          {:noreply,
           put_flash(
             socket |> refresh_agent_fleet(agent.id) |> clear_draft(drafted_key),
             :info,
             "#{ship_symbol} is navigating to #{target}."
           )}

        {:ok, %{status: "blocked", blocker: blocker, target_waypoint: target}} ->
          {:noreply,
           put_flash(
             socket |> refresh_agent_fleet(agent.id),
             :error,
             "Navigate to #{target} blocked: #{blocker_summary(blocker)}"
           )}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, live_error(reason))}
      end
    else
      {:error, message} -> {:noreply, put_flash(socket, :error, message)}
    end
  end

  @impl true
  def handle_event("stop_manual_intent", %{"symbol" => ship_symbol}, socket) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- Fleet.stop_manual_intent(agent, ship_symbol) do
      message = "#{ship_symbol} manual Navigate stopped; the Ship stays in Manual Control."

      {:noreply, put_flash(refresh_agent_fleet(socket, agent.id), :info, message)}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
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
  def handle_event(
        "install_module",
        %{"symbol" => ship_symbol, "module_symbol" => module_symbol},
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, intent} <- Fleet.install_module_intent(agent, ship_symbol, module_symbol) do
      {:noreply,
       put_flash(
         refresh_agent_fleet(socket, agent.id),
         :info,
         "#{module_symbol} installation #{manual_intent_status(intent)}."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "remove_module",
        %{"symbol" => ship_symbol, "module_symbol" => module_symbol},
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, intent} <-
           Fleet.remove_module_intent(agent, ship_symbol, module_symbol, %{module_symbol => 1}) do
      {:noreply,
       put_flash(
         refresh_agent_fleet(socket, agent.id),
         :info,
         "#{module_symbol} removal #{manual_intent_status(intent)}."
       )}
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
  def handle_event("configure_miner_job", params, socket) do
    save_miner_job(socket, params, :configure)
  end

  @impl true
  def handle_event("replace_miner_job", params, socket) do
    save_miner_job(socket, params, :replace)
  end

  @impl true
  def handle_event("configure_procurement_job", params, socket) do
    save_procurement_job(socket, params)
  end

  @impl true
  def handle_event("configure_construction_supply_job", params, socket) do
    save_construction_supply_job(socket, params)
  end

  @impl true
  def handle_event("configure_outfitting_job", params, socket) do
    save_outfitting_job(socket, params)
  end

  @impl true
  def handle_event("configure_explorer_job", %{"symbol" => ship_symbol}, socket) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, _job} <- Fleet.configure_explorer_job(agent, ship_symbol) do
      {:noreply,
       put_flash(
         refresh_agent(socket, agent),
         :info,
         "System Exploration Job assigned and paused."
       )}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "set_flight_mode",
        %{"symbol" => ship_symbol, "flight_mode" => flight_mode} = params,
        socket
      ) do
    draft_key = params["draft_key"] || draft_key("flight_mode", [ship_symbol])

    with {:ok, agent} <- agent_for_ship(socket, ship_symbol) do
      case Fleet.set_ship_flight_mode(agent, ship_symbol, flight_mode) do
        {:ok, %{nav: %{flight_mode: mode}}} ->
          {:noreply,
           put_flash(
             refresh_and_clear(socket, agent.id, draft_key),
             :info,
             "#{ship_symbol} flight mode set to #{mode}."
           )}

        {:ok, _result} ->
          {:noreply, refresh_and_clear(socket, agent.id, draft_key)}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, live_error(reason))}
      end
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
        %{
          "symbol" => ship_symbol,
          "waypoint" => waypoint,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, units} <- parse_units(units),
         {:ok, %{status: "completed"} = intent} <-
           Fleet.sell_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units) do
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("sell", [ship_symbol, trade_symbol]))

      {:noreply,
       put_flash(
         socket,
         :info,
         "Sold #{intent.last_action_result["units"] || 0} #{trade_symbol} for #{(intent.last_action_result["units"] || 0) * (intent.last_action_result["price"] || 0)} credits."
       )}
    else
      {:ok, intent} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           live_error(intent.last_action_result["error"] || intent.blocker.reason)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "purchase_cargo",
        %{
          "symbol" => ship_symbol,
          "waypoint" => waypoint,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         {:ok, units} <- parse_units(units),
         {:ok, %{status: "completed"} = intent} <-
           Fleet.buy_goods_intent(agent, ship_symbol, waypoint, trade_symbol, units) do
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("purchase", [ship_symbol, trade_symbol]))

      {:noreply,
       put_flash(
         socket,
         :info,
         "Bought #{intent.last_action_result["units"] || 0} #{trade_symbol} for #{(intent.last_action_result["units"] || 0) * (intent.last_action_result["price"] || 0)} credits."
       )}
    else
      {:ok, intent} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           live_error(intent.last_action_result["error"] || intent.blocker.reason)
         )}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, live_error(reason))}
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
  def handle_event(
        "transfer_cargo",
        %{
          "from_ship" => from_ship,
          "to_ship" => to_ship,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with {:ok, agent} <- agent_for_ship(socket, from_ship),
         {:ok, units} <- parse_units(units),
         {:ok, _result} <- Fleet.transfer_cargo(agent, from_ship, to_ship, trade_symbol, units) do
      {:noreply,
       put_flash(
         refresh_agent(socket, agent)
         |> clear_draft(draft_key("transfer", [from_ship])),
         :info,
         "Transferred #{units} #{trade_symbol} from #{from_ship} to #{to_ship}."
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

    {:noreply,
     socket
     |> load_waypoint_intelligence(agent_id, symbol, key)
     |> assign(selected_waypoints: selected_waypoints)}
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
          "destination_waypoint" => destination_waypoint,
          "ship_symbol" => ship_symbol,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with {:ok, agent, contract} <- agent_for_contract(socket, agent_id, contract_id),
         true <- Contracts.fulfillable?(contract),
         {:ok, units} <- parse_units(units),
         {:ok, %{status: "completed"}} <-
           Fleet.deliver_goods_intent(
             agent,
             ship_symbol,
             destination_waypoint,
             contract_id,
             trade_symbol,
             units
           ) do
      socket =
        refresh_agent(socket, agent)
        |> clear_draft(draft_key("deliver", [ship_symbol, contract_id, trade_symbol]))

      {:noreply, put_flash(socket, :info, "Delivered #{units} #{trade_symbol}.")}
    else
      {:ok, intent} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           if(intent.blocker,
             do: live_error(intent.last_action_result["error"] || intent.blocker.reason),
             else: "Deliver Goods Intent is #{intent.status}."
           )
         )}

      false ->
        {:noreply, put_flash(socket, :error, "This contract is no longer actionable.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(
        "deliver_construction",
        %{
          "agent_id" => agent_id,
          "system_symbol" => system_symbol,
          "destination_waypoint" => destination_waypoint,
          "ship_symbol" => ship_symbol,
          "trade_symbol" => trade_symbol,
          "units" => units
        },
        socket
      ) do
    with %{agent: agent} <-
           Enum.find(socket.assigns.overviews, &(to_string(&1.agent.id) == agent_id)),
         {:ok, units} <- parse_units(units),
         {:ok, %{status: "completed"}} <-
           Fleet.deliver_construction_goods_intent(
             agent,
             ship_symbol,
             system_symbol,
             destination_waypoint,
             trade_symbol,
             units
           ) do
      socket =
        refresh_agent(socket, agent)
        |> clear_draft(draft_key("deliver-construction", [ship_symbol, destination_waypoint]))

      {:noreply, put_flash(socket, :info, "Supplied #{units} #{trade_symbol}.")}
    else
      {:ok, intent} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           if(intent.blocker,
             do: live_error(intent.last_action_result["error"] || intent.blocker.reason),
             else: "Deliver Goods Intent is #{intent.status}."
           )
         )}

      nil ->
        {:noreply, put_flash(socket, :error, "That Construction project is not available.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, live_error(reason))}
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
      when action in [
             "pause_miner_job",
             "resume_miner_job",
             "reconcile_miner_job",
             "stop_miner_job",
             "row_pause_miner_job",
             "row_resume_miner_job",
             "row_reconcile_miner_job"
           ] do
    action = String.replace_prefix(action, "row_", "")

    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- miner_job_action(action, agent, ship_symbol) do
      message =
        case action do
          "pause_miner_job" -> "#{ship_symbol} Miner Job paused."
          "resume_miner_job" -> "#{ship_symbol} Miner Job resumed after revalidation."
          "reconcile_miner_job" -> "#{ship_symbol} Miner Job reconciled and retried."
          "stop_miner_job" -> "#{ship_symbol} Miner Job stopped; Ship is manual."
        end

      {:noreply, put_flash(refresh_agent(socket, agent), :info, message)}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(action, %{"symbol" => ship_symbol}, socket)
      when action in [
             "pause_explorer_job",
             "resume_explorer_job",
             "reconcile_explorer_job",
             "stop_explorer_job"
           ] do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- explorer_job_action(action, agent, ship_symbol) do
      message =
        case action do
          "pause_explorer_job" -> "#{ship_symbol} System Exploration Job paused."
          "resume_explorer_job" -> "#{ship_symbol} System Exploration Job resumed."
          "reconcile_explorer_job" -> "#{ship_symbol} System Exploration Job reconciled."
          "stop_explorer_job" -> "#{ship_symbol} System Exploration Job stopped; Ship is manual."
        end

      {:noreply, put_flash(refresh_agent(socket, agent), :info, message)}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
    end
  end

  @impl true
  def handle_event(action, %{"symbol" => ship_symbol}, socket)
      when action in [
             "pause_procurement_job",
             "resume_procurement_job",
             "stop_procurement_job",
             "pause_construction_supply_job",
             "resume_construction_supply_job",
             "stop_construction_supply_job",
             "pause_market_trading_job",
             "resume_market_trading_job",
             "stop_market_trading_job",
             "pause_outfitting_job",
             "resume_outfitting_job",
             "stop_outfitting_job"
           ] do
    with {:ok, agent} <- agent_for_ship(socket, ship_symbol),
         :ok <- job_action(action, agent, ship_symbol) do
      message =
        case action do
          "pause_procurement_job" ->
            "#{ship_symbol} Procurement Job paused."

          "resume_procurement_job" ->
            "#{ship_symbol} Procurement Job resumed."

          "stop_procurement_job" ->
            "#{ship_symbol} Procurement Job stopped; Ship is manual."

          "pause_construction_supply_job" ->
            "#{ship_symbol} Construction Supply Job paused."

          "resume_construction_supply_job" ->
            "#{ship_symbol} Construction Supply Job resumed."

          "stop_construction_supply_job" ->
            "#{ship_symbol} Construction Supply Job stopped; Ship is manual."

          "pause_market_trading_job" ->
            "#{ship_symbol} Market Trading Job paused."

          "resume_market_trading_job" ->
            "#{ship_symbol} Market Trading Job resumed."

          "stop_market_trading_job" ->
            "#{ship_symbol} Market Trading Job stopped; Ship is manual."

          "pause_outfitting_job" ->
            "#{ship_symbol} Ship Outfitting Job paused."

          "resume_outfitting_job" ->
            "#{ship_symbol} Ship Outfitting Job resumed."

          "stop_outfitting_job" ->
            "#{ship_symbol} Ship Outfitting Job stopped; Ship is manual."
        end

      {:noreply, put_flash(refresh_agent(socket, agent), :info, message)}
    else
      {:error, reason} ->
        {:noreply,
         put_flash(refresh_agent_for_ship(socket, ship_symbol), :error, live_error(reason))}
    end
  end

  defp miner_job_action("pause_miner_job", agent, ship),
    do: unwrap_config(Fleet.pause_miner_job(agent, ship))

  defp miner_job_action("resume_miner_job", agent, ship),
    do: unwrap_config(Fleet.resume_miner_job(agent, ship))

  defp miner_job_action("reconcile_miner_job", agent, ship),
    do: unwrap_config(Fleet.reconcile_miner_job(agent, ship))

  defp miner_job_action("stop_miner_job", agent, ship), do: Fleet.stop_miner_job(agent, ship)

  defp explorer_job_action("pause_explorer_job", agent, ship),
    do: unwrap_config(Fleet.pause_explorer_job(agent, ship))

  defp explorer_job_action("resume_explorer_job", agent, ship),
    do: unwrap_config(Fleet.resume_explorer_job(agent, ship))

  defp explorer_job_action("reconcile_explorer_job", agent, ship),
    do: unwrap_config(Fleet.reconcile_explorer_job(agent, ship))

  defp explorer_job_action("stop_explorer_job", agent, ship),
    do: Fleet.stop_explorer_job(agent, ship)

  defp procurement_job_action("pause_procurement_job", agent, ship),
    do: Fleet.pause_procurement_job(agent, ship) |> unwrap_job_result()

  defp procurement_job_action("resume_procurement_job", agent, ship),
    do: Fleet.resume_procurement_job(agent, ship) |> unwrap_job_result()

  defp procurement_job_action("stop_procurement_job", agent, ship),
    do: Fleet.stop_procurement_job(agent, ship)

  defp construction_supply_job_action("pause_construction_supply_job", agent, ship),
    do: Fleet.pause_construction_supply_job(agent, ship) |> unwrap_job_result()

  defp construction_supply_job_action("resume_construction_supply_job", agent, ship),
    do: Fleet.resume_construction_supply_job(agent, ship) |> unwrap_job_result()

  defp construction_supply_job_action("stop_construction_supply_job", agent, ship),
    do: Fleet.stop_construction_supply_job(agent, ship)

  defp outfitting_job_action("pause_outfitting_job", agent, ship),
    do: Fleet.pause_outfitting_job(agent, ship) |> unwrap_job_result()

  defp outfitting_job_action("resume_outfitting_job", agent, ship),
    do: Fleet.resume_outfitting_job(agent, ship) |> unwrap_job_result()

  defp outfitting_job_action("stop_outfitting_job", agent, ship),
    do: Fleet.stop_outfitting_job(agent, ship)

  defp job_action(action, agent, ship)
       when action in [
              "pause_procurement_job",
              "resume_procurement_job",
              "stop_procurement_job"
            ],
       do: procurement_job_action(action, agent, ship)

  defp job_action(action, agent, ship)
       when action in [
              "pause_construction_supply_job",
              "resume_construction_supply_job",
              "stop_construction_supply_job"
            ],
       do: construction_supply_job_action(action, agent, ship)

  defp job_action("pause_market_trading_job", agent, ship),
    do: Fleet.pause_market_trading_job(agent, ship) |> unwrap_job_result()

  defp job_action("resume_market_trading_job", agent, ship),
    do: Fleet.resume_market_trading_job(agent, ship) |> unwrap_job_result()

  defp job_action(action, agent, ship)
       when action in ["pause_outfitting_job", "resume_outfitting_job", "stop_outfitting_job"],
       do: outfitting_job_action(action, agent, ship)

  defp job_action("stop_market_trading_job", agent, ship),
    do: Fleet.stop_market_trading_job(agent, ship)

  defp unwrap_config({:ok, _config}), do: :ok
  defp unwrap_config(error), do: error

  defp save_miner_job(socket, params, mode) do
    with {:ok, agent} <- agent_for_ship(socket, params["ship_symbol"]),
         {:ok, threshold} <- parse_units(params["cargo_threshold"]),
         {:ok, _config} <-
           save_miner_job(mode, agent, params["ship_symbol"], %{
             extraction_waypoint: String.trim(params["extraction_waypoint"] || ""),
             market_waypoint: String.trim(params["market_waypoint"] || ""),
             cargo_threshold: threshold,
             gather_mode: params["gather_mode"] || "extract"
           }) do
      socket =
        socket
        |> refresh_agent(agent)
        |> clear_draft(draft_key("miner_job", [params["ship_symbol"]]))

      message =
        if mode == :replace,
          do: "Miner Job replaced.",
          else: "Miner Job assigned and paused."

      {:noreply, put_flash(socket, :info, message)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  defp save_miner_job(:configure, agent, ship_symbol, attrs),
    do: Fleet.configure_miner_job(agent, ship_symbol, attrs)

  defp save_miner_job(:replace, agent, ship_symbol, attrs),
    do: Fleet.replace_miner_job(agent, ship_symbol, attrs)

  defp save_procurement_job(socket, params) do
    with {:ok, agent} <- agent_for_ship(socket, params["ship_symbol"]),
         {:ok, quantity} <- parse_units(params["quantity"]),
         {:ok, reserve_credits} <- parse_optional_units(params["reserve_credits"]),
         {:ok, price_ceiling} <- parse_optional_units(params["price_ceiling"]),
         {:ok, minimum_sale_price} <- parse_optional_units(params["minimum_sale_price"]),
         {:ok, minimum_sale_value} <- parse_optional_units(params["minimum_sale_value"]),
         {:ok, _job} <-
           Fleet.configure_procurement_job(agent, params["ship_symbol"], %{
             recipient_type: params["recipient_type"] || "market",
             contract_id: blank_to_nil(params["contract_id"]),
             construction_system: blank_to_nil(params["construction_system"]),
             trade_symbol: String.trim(params["trade_symbol"] || ""),
             quantity: quantity,
             destination_waypoint: String.trim(params["destination_waypoint"] || ""),
             source_systems: split_systems(params["source_systems"]),
             reserve_credits: reserve_credits || 0,
             price_ceiling: price_ceiling,
             minimum_sale_price: minimum_sale_price,
             minimum_sale_value: minimum_sale_value,
             compatible_existing_cargo?: Map.has_key?(params, "compatible_existing_cargo")
           }) do
      {:noreply,
       put_flash(
         socket
         |> refresh_agent(agent)
         |> clear_draft(draft_key("procurement_job", [params["ship_symbol"]])),
         :info,
         "Procurement Job assigned and paused."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  defp save_construction_supply_job(socket, params) do
    with {:ok, agent} <- agent_for_ship(socket, params["ship_symbol"]),
         {:ok, reserve_credits} <- parse_optional_units(params["reserve_credits"]),
         {:ok, maximum_total_cost} <- parse_optional_units(params["maximum_total_cost"]),
         {:ok, _job} <-
           Fleet.configure_construction_supply_job(agent, params["ship_symbol"], %{
             construction_system: blank_to_nil(params["construction_system"]),
             construction_waypoint: String.trim(params["construction_waypoint"] || ""),
             source_systems: split_systems(params["source_systems"]),
             reserve_credits: reserve_credits || 0,
             maximum_total_cost: maximum_total_cost,
             compatible_existing_cargo?: Map.has_key?(params, "compatible_existing_cargo")
           }) do
      {:noreply,
       put_flash(
         socket
         |> refresh_agent(agent)
         |> clear_draft(draft_key("construction_supply_job", [params["ship_symbol"]])),
         :info,
         "Construction Supply Job assigned and paused."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  defp save_outfitting_job(socket, params) do
    with {:ok, agent} <- agent_for_ship(socket, params["ship_symbol"]),
         {:ok, authorized_removals} <- parse_authorized_removals(params["authorized_removals"]),
         {:ok, reserve_credits} <- parse_optional_units(params["reserve_credits"]),
         {:ok, maximum_total_cost} <- parse_required_units(params["maximum_total_cost"]),
         {:ok, _job} <-
           Fleet.configure_outfitting_job(agent, params["ship_symbol"], %{
             requested_capability: String.trim(params["requested_capability"] || ""),
             acceptable_modules: split_module_symbols(params["acceptable_modules"]),
             authorized_removals: authorized_removals,
             source_waypoints: split_systems(params["source_waypoints"]),
             reserve_credits: reserve_credits || 0,
             maximum_total_cost: maximum_total_cost
           }) do
      {:noreply,
       put_flash(
         socket
         |> refresh_agent(agent)
         |> clear_draft(draft_key("outfitting_job", [params["ship_symbol"]])),
         :info,
         "Ship Outfitting Job assigned and paused."
       )}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, live_error(reason))}
    end
  end

  defp split_module_symbols(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp split_module_symbols(_), do: []

  defp parse_authorized_removals(nil), do: {:ok, %{}}
  defp parse_authorized_removals(""), do: {:ok, %{}}

  defp parse_authorized_removals(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn entry, {:ok, removals} ->
      case String.split(entry, ":", parts: 2) do
        [symbol, count] ->
          case Integer.parse(String.trim(count)) do
            {count, ""} when count > 0 ->
              {:cont, {:ok, Map.put(removals, String.trim(symbol), count)}}

            _ ->
              {:halt, {:error, :invalid_outfitting_configuration}}
          end

        _ ->
          {:halt, {:error, :invalid_outfitting_configuration}}
      end
    end)
  end

  defp parse_authorized_removals(_), do: {:error, :invalid_outfitting_configuration}

  defp parse_optional_units(nil), do: {:ok, nil}
  defp parse_optional_units(""), do: {:ok, nil}
  defp parse_optional_units(value), do: parse_units(value)

  defp parse_required_units(value) do
    with {:ok, units} <- parse_units(value),
         true <- units > 0 do
      {:ok, units}
    else
      _ -> {:error, :invalid_outfitting_configuration}
    end
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp blank_to_nil(value), do: value

  defp split_systems(value) when is_binary(value) do
    value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  defp split_systems(_value), do: []

  defp unwrap_job_result({:ok, _job}), do: :ok
  defp unwrap_job_result(error), do: error

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

        %{waypoints: {:ok, waypoints}, agent: agent} when is_list(waypoints) ->
          case Enum.find(waypoints, &(&1.symbol == symbol)) do
            nil -> {:error, :waypoint_unavailable}
            waypoint -> Fleet.waypoint_market(agent, waypoint)
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

  defp load_waypoint_intelligence(socket, agent_id, symbol, key) do
    facts =
      case Enum.find(socket.assigns.overviews, &(to_string(&1.agent.id) == agent_id)) do
        %{agent: agent, waypoints: {:ok, waypoints}} ->
          case Enum.find(waypoints, &(&1.symbol == symbol)) do
            nil ->
              %{}

            waypoint ->
              load_waypoint_readiness(agent, waypoint)
          end

        _ ->
          %{}
      end

    update(socket, :waypoint_intelligence, &Map.put(&1, key, facts))
  end

  defp load_waypoint_readiness(agent, waypoint) do
    waypoint_facts =
      Intelligence.subject(agent, :waypoint, waypoint.system_symbol, waypoint.symbol)

    if waypoint.is_under_construction == true do
      _ = Fleet.waypoint_construction(agent, waypoint)
    end

    construction =
      Intelligence.subject_with_stale(
        agent,
        :construction,
        waypoint.system_symbol,
        waypoint.symbol
      )

    if waypoint.type == "JUMP_GATE" do
      _ = Fleet.waypoint_jump_gate(agent, waypoint)
    end

    gate =
      Intelligence.subject_with_stale(agent, :jump_gate, waypoint.system_symbol, waypoint.symbol)

    waypoint_facts
    |> Map.merge(namespace_readiness_facts(construction.current, "construction"))
    |> Map.merge(namespace_readiness_facts(construction.stale, "construction_stale"))
    |> Map.merge(namespace_readiness_facts(gate.current, "jump_gate"))
    |> Map.merge(namespace_readiness_facts(gate.stale, "jump_gate_stale"))
  end

  defp namespace_readiness_facts(facts, namespace) do
    Map.new(facts, fn {field, fact} -> {"#{namespace}.#{field}", fact} end)
  end

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
    ship_fields = Map.take(result, [:cargo, :cooldown, :fuel, :nav])

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
  attr :waypoint_intelligence, :map, default: %{}
  attr :selected_ships, :map, default: %{}
  attr :jump_previews, :map, default: %{}

  defp agent_section(assigns) do
    ~H"""
    <section class="space-y-5 border-t border-base-300/70 pt-6">
      <.agent_overview_card agent={@overview.agent} live={@overview.overview} />
      <.system_map
        waypoints={@overview.waypoints}
        ships={@overview.ships}
        agent_id={@overview.agent.id}
        headquarters_system={headquarters_system(@overview.agent.headquarters)}
        selected_symbol={Map.get(@selected_waypoints, to_string(@overview.agent.id))}
        filter={Map.get(@waypoint_filters, to_string(@overview.agent.id), "all")}
        waypoint_markets={@waypoint_markets}
        waypoint_intelligence={@waypoint_intelligence}
        form_drafts={@form_drafts}
      />
      <.fleet_grid
        agent={@overview.agent}
        ships={@overview.ships}
        cooldown_tick={@cooldown_tick}
        form_drafts={@form_drafts}
        selected_ship={Map.get(@selected_ships, to_string(@overview.agent.id))}
        jump_previews={@jump_previews}
      />
      <.fleet_attention
        agent_id={@overview.agent.id}
        ships={@overview.ships}
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
    </section>
    """
  end

  attr :stale_agents, :list, required: true

  defp stale_agent_card(assigns) do
    ~H"""
    <section :if={@stale_agents != []} class="rounded-2xl border border-warning/40 bg-warning/10 p-5">
      <p class="eyebrow">Server reset recovery</p>
      <h2 class="mt-1 text-xl font-bold">Your stale Agents are no longer available</h2>
      <p class="mt-2 text-sm leading-6">
        The game reset and invalidated {Enum.map_join(@stale_agents, ", ", & &1.symbol)}. Retire these stale local records, or mint a replacement Agent.
      </p>
      <div class="mt-4 flex flex-wrap gap-3">
        <button
          id="retire-stale-agents"
          type="button"
          phx-click="retire_stale_agents"
          class="btn btn-warning"
        >
          Retire stale Agents
        </button>
        <.link navigate={~p"/agents/new"} class="btn btn-ghost">Mint a replacement</.link>
      </div>
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
              <input type="hidden" name="destination_waypoint" value={good.destination_symbol} />
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
                  <% purchase_action = Map.get(Map.get(listing, :purchase_actions, %{}), ship.type) %>
                  <input type="hidden" name="agent_id" value={@agent_id} />
                  <input type="hidden" name="ship_type" value={ship.type} />
                  <input type="hidden" name="waypoint" value={listing.waypoint} />
                  <span class="font-mono">{credits_label(ship.purchase_price)} cr</span>
                  <.action_tooltip reason={action_reason(purchase_action)}>
                    <button
                      type="submit"
                      disabled={not action_allowed?(purchase_action)}
                      class="btn btn-primary btn-xs"
                    >
                      Buy
                    </button>
                  </.action_tooltip>
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
                id={"sell-form-#{listing.waypoint}-#{ship.symbol}-#{good.symbol}"}
                phx-change="track_draft"
                phx-submit="sell_cargo"
                class="flex items-center gap-2"
              >
                <% sell_action = trade_action(ship, good.symbol, :sell) %>
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="waypoint" value={listing.waypoint} />
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
                <.action_tooltip reason={action_reason(sell_action)}>
                  <button
                    type="submit"
                    disabled={not action_allowed?(sell_action)}
                    class="btn btn-secondary btn-xs"
                  >Sell</button>
                </.action_tooltip>
              </form>
              <form
                :for={ship <- listing.ships}
                id={"buy-form-#{listing.waypoint}-#{ship.symbol}-#{good.symbol}"}
                phx-change="track_draft"
                phx-submit="purchase_cargo"
                class="flex items-center gap-2"
              >
                <% buy_action = trade_action(ship, good.symbol, :buy) %>
                <input type="hidden" name="symbol" value={ship.symbol} />
                <input type="hidden" name="waypoint" value={listing.waypoint} />
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
                <.action_tooltip reason={action_reason(buy_action)}>
                  <button
                    type="submit"
                    disabled={not action_allowed?(buy_action)}
                    class="btn btn-primary btn-xs"
                  >Buy</button>
                </.action_tooltip>
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
  attr :waypoint_intelligence, :map, default: %{}
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
                      intelligence={
                        Map.get(@waypoint_intelligence, {to_string(@agent_id), @selected_symbol}, %{})
                      }
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
            intelligence={
              Map.get(@waypoint_intelligence, {to_string(@agent_id), @selected_symbol}, %{})
            }
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
  attr :intelligence, :map, default: %{}
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
          <details :if={map_size(@intelligence) > 0} class="mt-4" data-operational-intelligence>
            <summary class="cursor-pointer text-xs font-semibold uppercase tracking-wider opacity-60">
              Operational Intelligence
            </summary>
            <dl class="mt-2 space-y-2 text-sm">
              <div :for={{field, fact} <- Enum.sort_by(@intelligence, &elem(&1, 0))}>
                <dt class="font-mono text-xs">{field}</dt>
                <dd class="opacity-70">
                  <span class="badge badge-outline badge-xs">{fact.state}</span>
                  <span class="ml-1">{fact.observation.source}</span>
                  <span :if={fact.observation.observing_ship_symbol} class="ml-1 font-mono text-xs">
                    observed by {fact.observation.observing_ship_symbol}
                  </span>
                  <time class="ml-1 font-mono text-xs">{DateTime.to_iso8601(
                    fact.observation.observed_at
                  )}</time>
                </dd>
              </div>
            </dl>
          </details>
          <.readiness_facts
            facts={@intelligence}
            namespace="construction"
            title="Construction readiness"
          />
          <form
            :for={ship <- construction_delivery_ships(@ships, waypoint.symbol)}
            :if={waypoint.is_under_construction == true}
            id={"deliver-construction-#{@agent_id}-#{waypoint.symbol}-#{ship.symbol}"}
            phx-change="track_draft"
            phx-submit="deliver_construction"
            class="mt-4 grid grid-cols-[minmax(0,1fr)_5rem_auto] gap-2 sm:flex"
            data-construction-delivery
          >
            <input type="hidden" name="agent_id" value={@agent_id} />
            <input type="hidden" name="system_symbol" value={waypoint.system_symbol} />
            <input type="hidden" name="destination_waypoint" value={waypoint.symbol} />
            <input type="hidden" name="ship_symbol" value={ship.symbol} />
            <input
              type="hidden"
              name="draft_key"
              value={draft_key("deliver-construction", [ship.symbol, waypoint.symbol])}
            />
            <input
              name="trade_symbol"
              placeholder="Trade good"
              value={
                draft_field(
                  @form_drafts,
                  "deliver-construction",
                  [ship.symbol, waypoint.symbol],
                  "trade_symbol",
                  ""
                )
              }
              class="input input-bordered input-sm w-full font-mono"
              required
            />
            <input
              name="units"
              type="number"
              min="1"
              value={
                draft_field(
                  @form_drafts,
                  "deliver-construction",
                  [ship.symbol, waypoint.symbol],
                  "units",
                  1
                )
              }
              class="input input-bordered input-sm w-full sm:w-20"
              required
            />
            <button type="submit" class="btn btn-secondary btn-sm">Supply</button>
          </form>
          <.readiness_facts
            facts={@intelligence}
            namespace="jump_gate"
            title="Jump-gate connections"
          />
          <.readiness_facts
            facts={@intelligence}
            namespace="construction_stale"
            title="Stale Construction readiness"
          />
          <.readiness_facts
            facts={@intelligence}
            namespace="jump_gate_stale"
            title="Stale Jump-gate connections"
          />
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
                <p :if={market_has_fuel?(market)} class="mt-3 text-sm text-success" data-market-fuel>
                  Fuel available: dock here to refuel the Ship tank.
                </p>
                <p
                  :if={not market_has_fuel?(market)}
                  class="mt-3 text-sm text-warning"
                  data-market-no-fuel
                >
                  No fuel listing reported. Choose another Marketplace for recovery.
                </p>
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

  attr :facts, :map, required: true
  attr :namespace, :string, required: true
  attr :title, :string, required: true

  defp readiness_facts(assigns) do
    prefix = "#{assigns.namespace}."

    facts =
      Enum.filter(assigns.facts, fn {field, _fact} -> String.starts_with?(field, prefix) end)

    assigns = assign(assigns, :facts, facts)

    ~H"""
    <section :if={@facts != []} class="mt-4" data-readiness={@namespace}>
      <p class="text-xs font-semibold uppercase tracking-wider opacity-60">{@title}</p>
      <dl class="mt-2 space-y-2 text-sm">
        <div :for={{field, fact} <- @facts}>
          <dt class="font-mono text-xs">{String.replace_prefix(field, "#{@namespace}.", "")}</dt>
          <dd class="opacity-70">
            <span class="badge badge-outline badge-xs">{fact.state}</span>
            <span class="ml-1">{inspect(fact.value)}</span>
            <span class="ml-1">{fact.observation.source}</span>
            <span :if={fact.observation.observing_ship_symbol} class="ml-1 font-mono text-xs">
              observed by {fact.observation.observing_ship_symbol}
            </span>
            <time class="ml-1 font-mono text-xs">{DateTime.to_iso8601(fact.observation.observed_at)}</time>
          </dd>
        </div>
      </dl>
    </section>
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
  attr :jump_previews, :map, default: %{}

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
              ships={ships}
              agent_id={@agent.id}
              cooldown_tick={@cooldown_tick}
              form_drafts={@form_drafts}
              jump_preview={Map.get(@jump_previews, ship.symbol)}
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

  attr :agent_id, :integer, required: true
  attr :ships, :any, required: true
  attr :selected_ship, :string, default: nil

  defp fleet_attention(assigns) do
    attention =
      case assigns.ships do
        {:ok, ships} -> Enum.filter(ships, &needs_attention?/1)
        _ -> []
      end

    assigns = assign(assigns, :attention, attention)

    ~H"""
    <section
      :if={@attention != []}
      class="card border border-warning/40 bg-warning/10 p-4"
      data-fleet-attention
    >
      <p class="eyebrow">Needs attention</p>
      <h3 class="mt-1 text-lg font-semibold">Resolve blocked work before reviewing history</h3>
      <ul class="mt-3 space-y-2">
        <li
          :for={ship <- @attention}
          class="flex flex-wrap items-center justify-between gap-2 rounded border border-warning/30 p-3"
        >
          <div>
            <span class="font-mono font-semibold">{ship.symbol}</span>
            <span class="ml-2 text-sm">{attention_summary(ship)}</span>
          </div>
          <button
            :if={@selected_ship != ship.symbol}
            type="button"
            phx-click="select_ship"
            phx-value-agent_id={@agent_id}
            phx-value-symbol={ship.symbol}
            class="btn btn-primary btn-sm"
            data-open-attention={ship.symbol}
          >Resolve</button>
          <span :if={@selected_ship == ship.symbol} class="badge badge-primary">Open in Ship console</span>
        </li>
      </ul>
    </section>
    """
  end

  defp source_waypoint_label([]), do: "any Market"
  defp source_waypoint_label(waypoints) when is_list(waypoints), do: Enum.join(waypoints, ", ")
  defp source_waypoint_label(_), do: "any Market"

  attr :ship, :map, required: true
  attr :ships, :list, required: true
  attr :agent_id, :integer, required: true
  attr :cooldown_tick, :integer, default: 0
  attr :form_drafts, :map, default: %{}
  attr :jump_preview, :map, default: nil
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

      <div class="mt-3 flex flex-wrap items-center gap-2 text-xs" data-ship-row-status>
        <span :if={@ship.job} class="badge badge-outline badge-sm">{job_status(@ship.job)}</span>
        <span
          :if={@ship.manual_intent}
          class={manual_intent_status_class(@ship.manual_intent)}
          data-row-manual-intent
        >
          Manual: {manual_intent_status(@ship.manual_intent)}
        </span>
        <span :if={job_reason(@ship.job)} class="truncate text-warning" data-row-attention>
          {job_reason(@ship.job)}
        </span>
        <button
          :if={not @selected and Job.running?(@ship.job)}
          type="button"
          phx-click="row_pause_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-xs"
        >
          Pause
        </button>
        <button
          :if={
            (not @selected and @ship.job) &&
              (@ship.job.status == "paused" or
                 (@ship.job.status == "blocked" and
                    not (match?(%JobBlocker{}, @ship.job.blocker) and
                           is_map(@ship.job.in_flight_action))))
          }
          type="button"
          phx-click="row_resume_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-xs"
        >
          Resolve
        </button>
        <button
          :if={
            (not @selected and @ship.job) && @ship.job.status == "blocked" &&
              match?(%JobBlocker{}, @ship.job.blocker) &&
              is_map(@ship.job.in_flight_action)
          }
          type="button"
          phx-click="row_reconcile_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-xs"
        >
          Resolve
        </button>
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
            <button
              :if={String.starts_with?(item.symbol, "MODULE_")}
              type="button"
              phx-click="install_module"
              phx-value-symbol={@ship.symbol}
              phx-value-module_symbol={item.symbol}
              class="btn btn-primary btn-xs"
              data-install-module={item.symbol}
            >
              Install module
            </button>
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
        <p class="mt-4 text-xs font-semibold uppercase tracking-wider opacity-60">
          Cargo &amp; Trade
        </p>
        <%= cond do %>
          <% @ship.job && @ship.job.type == "explorer" -> %>
            <.explorer_job_panel ship={@ship} />
          <% @ship.job && @ship.job.type == "procurement" -> %>
            <.procurement_job_panel ship={@ship} />
          <% @ship.job && @ship.job.type == "construction_supply" -> %>
            <.construction_supply_job_panel ship={@ship} />
          <% @ship.job && @ship.job.type == "outfitting" -> %>
            <.outfitting_job_panel ship={@ship} form_drafts={@form_drafts} />
          <% true -> %>
            <.miner_job_panel ship={@ship} form_drafts={@form_drafts} />
            <.procurement_job_panel ship={@ship} form_drafts={@form_drafts} />
            <.construction_supply_job_panel ship={@ship} form_drafts={@form_drafts} />
            <.outfitting_job_panel ship={@ship} form_drafts={@form_drafts} />
            <button
              :if={is_nil(@ship.job)}
              type="button"
              phx-click="configure_explorer_job"
              phx-value-symbol={@ship.symbol}
              class="btn btn-outline btn-sm mt-2"
              data-configure-explorer-job
            >Assign System Exploration Job</button>
        <% end %>

        <.transfer_panel ship={@ship} ships={@ships} form_drafts={@form_drafts} />

        <p class="mt-4 text-xs font-semibold uppercase tracking-wider opacity-60">Navigation</p>

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
              <div class="flex items-center justify-between gap-3">
                <dt class="opacity-60">Fuel used</dt>
                <dd class="font-mono">{fuel_consumed_label(@ship)}</dd>
              </div>
            </dl>
          </details>
        <% end %>
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
          <.action_tooltip reason={action_reason(ship_action_state(@ship, :navigate))}>
            <button
              type="submit"
              disabled={not action_allowed?(ship_action_state(@ship, :navigate))}
              class="btn btn-primary min-h-11 btn-sm"
            >
              Navigate
            </button>
          </.action_tooltip>
        </form>
        <section
          :if={@jump_preview}
          class="mt-2 rounded border border-primary/40 bg-primary/10 p-3 text-xs"
          data-jump-preview
        >
          <p class="font-semibold">Jump route ready for review</p>
          <dl class="mt-2 grid grid-cols-2 gap-x-3 gap-y-1">
            <dt class="opacity-70">Selected gates</dt>
            <dd class="font-mono">
              {@jump_preview.source_waypoint} to {@jump_preview.destination_waypoint}
            </dd>
            <dt class="opacity-70">Flight mode</dt>
            <dd class="font-mono">{@jump_preview.flight_mode}</dd>
            <dt class="opacity-70">Credits</dt>
            <dd class="font-mono">{@jump_preview.credits}</dd>
            <dt class="opacity-70">Jump cost</dt>
            <dd>{@jump_preview.antimatter_cost} credits for one antimatter charge.</dd>
            <dt class="opacity-70">Cooldown</dt>
            <dd>{@jump_preview.cooldown_seconds || 0} seconds before dispatch.</dd>
          </dl>
          <form phx-submit="navigate" phx-value-symbol={@ship.symbol} class="mt-3">
            <input type="hidden" name="waypoint_symbol" value={@jump_preview.destination_waypoint} />
            <input type="hidden" name="confirm_jump" value="true" />
            <input type="hidden" name="source_waypoint" value={@jump_preview.source_waypoint} />
            <input
              type="hidden"
              name="destination_waypoint"
              value={@jump_preview.destination_waypoint}
            />
            <input type="hidden" name="flight_mode" value={@jump_preview.flight_mode} />
            <input type="hidden" name="antimatter_cost" value={@jump_preview.antimatter_cost} />
            <button type="submit" class="btn btn-primary btn-sm">Confirm jump</button>
          </form>
        </section>
        <div
          :if={@ship.manual_intent}
          class="mt-2 flex flex-wrap items-center justify-between gap-2 rounded border border-base-300/60 bg-base-300/30 px-3 py-2 text-xs"
          data-manual-intent={@ship.manual_intent.status}
        >
          <div>
            <span class="font-semibold">Manual Control</span>
            <span class="ml-1">
              {manual_intent_label(@ship.manual_intent)}
            </span>
            <span class={manual_intent_status_class(@ship.manual_intent)}>
              {manual_intent_status(@ship.manual_intent)}
            </span>
            <div :if={manual_intent_reason(@ship.manual_intent)} class="mt-1 opacity-70">
              {manual_intent_reason(@ship.manual_intent)}
            </div>
          </div>
          <button
            type="button"
            phx-click="stop_manual_intent"
            phx-value-symbol={@ship.symbol}
            class="btn btn-ghost btn-xs"
          >
            Stop
          </button>
        </div>
        <p class="mt-2 text-xs opacity-60">
          The game API remains authoritative for route fuel requirements.
        </p>
        <details id={"posture-actions-#{@ship.symbol}"} class="mt-2" data-posture-actions>
          <summary class="cursor-pointer text-xs opacity-70">Posture &amp; direct actions</summary>
          <div class="mt-2 flex flex-wrap gap-2">
            <.action_tooltip reason={action_reason(ship_action_state(@ship, :dock))}>
              <button
                type="button"
                phx-click="dock"
                phx-value-symbol={@ship.symbol}
                disabled={not action_allowed?(ship_action_state(@ship, :dock))}
                class="btn btn-ghost min-h-10 btn-sm"
              >
                Dock
              </button>
            </.action_tooltip>
            <.action_tooltip reason={action_reason(ship_action_state(@ship, :orbit))}>
              <button
                type="button"
                phx-click="orbit"
                phx-value-symbol={@ship.symbol}
                disabled={not action_allowed?(ship_action_state(@ship, :orbit))}
                class="btn btn-ghost min-h-10 btn-sm"
              >
                Orbit
              </button>
            </.action_tooltip>
            <.action_tooltip reason={action_reason(ship_action_state(@ship, :extract))}>
              <button
                type="button"
                phx-click="extract"
                phx-value-symbol={@ship.symbol}
                disabled={not action_allowed?(ship_action_state(@ship, :extract))}
                class="btn btn-ghost min-h-10 btn-sm"
              >
                Extract
              </button>
            </.action_tooltip>
            <.action_tooltip reason={action_reason(ship_action_state(@ship, :siphon))}>
              <button
                type="button"
                phx-click="siphon"
                phx-value-symbol={@ship.symbol}
                disabled={not action_allowed?(ship_action_state(@ship, :siphon))}
                class="btn btn-ghost min-h-10 btn-sm"
              >
                Siphon
              </button>
            </.action_tooltip>
            <.action_tooltip reason={action_reason(ship_action_state(@ship, :refuel))}>
              <button
                type="button"
                phx-click="refuel"
                phx-value-symbol={@ship.symbol}
                disabled={not action_allowed?(ship_action_state(@ship, :refuel))}
                class="btn btn-ghost min-h-10 btn-sm"
              >
                Refuel
              </button>
            </.action_tooltip>
          </div>
        </details>
      </div>

      <details
        id={"ship-readiness-#{@ship.symbol}"}
        class={"mt-4 border-t border-base-300/60 pt-3 #{operations_class(@selected)}"}
        data-ship-readiness
        data-console-section="ship"
      >
        <summary class="cursor-pointer text-sm font-semibold">Ship Readiness</summary>
        <div class="mt-3 space-y-4 text-sm">
          <div class="grid grid-cols-1 gap-3 sm:grid-cols-3">
            <div>
              <div class="text-xs opacity-60">Flight Mode</div>
              <div class="font-mono">{flight_mode(@ship)}</div>
              <form
                id={"flight-mode-form-#{@ship.symbol}"}
                phx-change="track_draft"
                phx-submit="set_flight_mode"
                phx-value-symbol={@ship.symbol}
                class="mt-2 flex gap-2"
              >
                <input
                  type="hidden"
                  name="draft_key"
                  value={draft_key("flight_mode", [@ship.symbol])}
                />
                <select
                  name="flight_mode"
                  class="select select-bordered select-xs min-w-0 flex-1 font-mono"
                  disabled={not action_allowed?(ship_action_state(@ship, :set_flight_mode))}
                >
                  <option
                    :for={mode <- ["DRIFT", "STEALTH", "CRUISE", "BURN"]}
                    value={mode}
                    selected={
                      draft_field(
                        @form_drafts,
                        "flight_mode",
                        [@ship.symbol],
                        "flight_mode",
                        flight_mode(@ship)
                      ) ==
                        mode
                    }
                  >
                    {mode}
                  </option>
                </select>
                <.action_tooltip reason={action_reason(ship_action_state(@ship, :set_flight_mode))}>
                  <button
                    type="submit"
                    disabled={not action_allowed?(ship_action_state(@ship, :set_flight_mode))}
                    class="btn btn-ghost btn-xs"
                  >
                    Set
                  </button>
                </.action_tooltip>
              </form>
              <p class="mt-1 text-xs opacity-60">DRIFT minimizes fuel use before a recovery route.</p>
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
            <div class="flex items-center justify-between gap-2">
              <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Modules</p>
              <span class="font-mono text-xs opacity-60" data-module-capacity>
                {length(@ship.modules || [])} / {module_slots(@ship)} module slots
              </span>
            </div>
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
                <button
                  type="button"
                  phx-click="remove_module"
                  phx-value-symbol={@ship.symbol}
                  phx-value-module_symbol={module.symbol}
                  class="btn btn-ghost btn-xs mt-2"
                  data-remove-module={module.symbol}
                >
                  Remove module
                </button>
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
      <section
        class={"mt-4 border-t border-base-300/60 pt-3 #{operations_class(@selected)}"}
        data-sensor-controls
      >
        <p class="text-sm font-semibold">Sensors</p>
        <p class="mt-1 text-xs opacity-60">Sensor controls are unavailable for this Ship.</p>
      </section>
    </div>
    """
  end

  attr :ship, :map, required: true
  attr :ships, :list, required: true
  attr :form_drafts, :map, default: %{}

  defp transfer_panel(assigns) do
    ~H"""
    <div
      :if={transfer_targets(@ship, @ships) != [] and cargo_inventory(@ship) != []}
      class="mt-4 rounded border border-base-300/60 p-3"
    >
      <p class="text-xs font-semibold uppercase tracking-wide opacity-60">Transfer cargo</p>
      <form
        id={"transfer-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit="transfer_cargo"
        class="mt-2 grid grid-cols-1 gap-2 sm:grid-cols-4"
      >
        <input type="hidden" name="from_ship" value={@ship.symbol} />
        <input
          type="hidden"
          name="draft_key"
          value={
            draft_key("transfer", [
              @ship.symbol
            ])
          }
        />
        <select name="to_ship" class="select select-bordered select-sm">
          <option
            :for={target <- transfer_targets(@ship, @ships)}
            value={target.symbol}
            selected={
              draft_field(
                @form_drafts,
                "transfer",
                [@ship.symbol],
                "to_ship",
                transfer_target(@ship, @ships)
              ) == target.symbol
            }
          >
            {target.symbol}
          </option>
        </select>
        <select name="trade_symbol" class="select select-bordered select-sm">
          <option
            :for={item <- cargo_inventory(@ship)}
            value={item.symbol}
            selected={
              draft_field(
                @form_drafts,
                "transfer",
                [@ship.symbol],
                "trade_symbol",
                transfer_symbol(@ship)
              ) == item.symbol
            }
          >
            {item.symbol}
          </option>
        </select>
        <input
          type="number"
          name="units"
          min="1"
          max={cargo_units(transfer_item(@ship, @form_drafts))}
          value={
            draft_field(
              @form_drafts,
              "transfer",
              [@ship.symbol],
              "units",
              cargo_units(transfer_item(@ship, @form_drafts))
            )
          }
          class="input input-bordered input-sm"
        />
        <button type="submit" class="btn btn-secondary btn-sm">Transfer</button>
      </form>
    </div>
    """
  end

  attr :ship, :map, required: true
  attr :form_drafts, :map, default: %{}

  defp explorer_job_panel(assigns) do
    coverage = get_in(assigns.ship.job.progress || %{}, ["coverage"]) || %{}
    unresolved = Enum.filter(coverage, fn {_symbol, missing} -> missing != [] end)
    methods = get_in(assigns.ship.job.progress || %{}, ["methods"]) || %{}
    viability = get_in(assigns.ship.job.progress || %{}, ["viability"]) || %{}

    assigns =
      assign(assigns,
        coverage: coverage,
        unresolved: unresolved,
        methods: methods,
        viability: viability
      )

    ~H"""
    <section class="mt-4 rounded border border-base-300 p-3" data-explorer-job-panel>
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">System Exploration Job</span>
        <span class="badge badge-sm">{job_status(@ship.job)}</span>
      </div>
      <p class="mt-2 text-xs opacity-70" data-explorer-target-system>
        Target System:
        <span class="font-mono">{get_in(@ship.job.progress || %{}, ["target_system"])}</span>
      </p>
      <p class="mt-1 text-xs opacity-70" data-explorer-coverage>
        Completed coverage: {map_size(@coverage) - length(@unresolved)} / {map_size(@coverage)} Waypoints
      </p>
      <p :if={@ship.job.in_flight_action} class="mt-1 text-xs opacity-70" data-explorer-active-method>
        Active method: {Map.get(@ship.job.in_flight_action, "method") ||
          Map.get(@ship.job.in_flight_action, "kind")}
      </p>
      <div :if={@unresolved != []} class="mt-2 text-xs" data-explorer-unresolved>
        <p class="font-semibold">Unresolved coverage</p>
        <p :for={{symbol, missing} <- @unresolved} class="font-mono opacity-70">
          {symbol}: {Enum.join(missing, ", ")}
        </p>
      </div>
      <div :if={map_size(@methods) > 0} class="mt-2 text-xs" data-explorer-methods>
        <p class="font-semibold">Acquisition methods</p>
        <p :for={{subject, method} <- @methods} class="font-mono opacity-70">
          {subject}: {method}
        </p>
      </div>
      <div :if={map_size(@viability) > 0} class="mt-2 text-xs text-warning" data-explorer-viability>
        <p class="font-semibold">Viability blockers</p>
        <p :for={{subject, reason} <- @viability} class="font-mono opacity-70">
          {subject}: {reason}
        </p>
      </div>
      <p :if={@ship.job.blocker} class="mt-2 text-xs text-warning" data-explorer-blocker>
        {@ship.job.blocker.summary} {@ship.job.blocker.retry_condition}
      </p>
      <div class="mt-3 flex flex-wrap gap-2">
        <button
          type="button"
          phx-click="pause_explorer_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-ghost btn-xs"
        >Pause</button>
        <button
          type="button"
          phx-click="resume_explorer_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-xs"
        >Resume</button>
        <button
          type="button"
          phx-click="reconcile_explorer_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-ghost btn-xs"
        >Reconcile</button>
        <button
          type="button"
          phx-click="stop_explorer_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-error btn-outline btn-xs"
        >Stop</button>
      </div>
    </section>
    """
  end

  attr :ship, :map, required: true
  attr :form_drafts, :map, default: %{}

  defp procurement_job_panel(assigns) do
    job = Map.get(assigns.ship, :job)
    progress = (job && job.progress) || %{}
    assigns = assign(assigns, job: job, progress: progress)

    ~H"""
    <section class="mt-4 rounded border border-secondary/30 p-3" data-job-panel="procurement">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">Procurement Job</span>
        <span class="badge badge-outline badge-sm" data-procurement-job-status>
          {job_status(@job)}
        </span>
      </div>
      <dl :if={@job} class="mt-3 grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
        <div>
          <dt class="opacity-60">Cargo</dt><dd>
            {@progress["trade_symbol"]} · {@progress["aboard"] || 0} / {@progress["requested"] || 0}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Destination</dt><dd class="font-mono">
            {@progress["destination_waypoint"]}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Active work</dt><dd>{job_active_work(@job, @ship)}</dd>
        </div>
        <div>
          <dt class="opacity-60">Next expected transition</dt><dd>
            {job_next_transition(@job, @ship)}
          </dd>
        </div>
      </dl>
      <p :if={job_reason(@job)} class="mt-2 text-xs text-error" data-procurement-job-reason>
        {job_reason(@job)}
      </p>
      <form
        :if={is_nil(@job)}
        id={"procurement-job-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit="configure_procurement_job"
        class="mt-3 grid gap-2 sm:grid-cols-2"
      >
        <input type="hidden" name="draft_key" value={draft_key("procurement_job", [@ship.symbol])} />
        <input type="hidden" name="ship_symbol" value={@ship.symbol} />
        <select
          name="recipient_type"
          class="select select-bordered select-sm"
          aria-label="Recipient type"
        >
          <option
            value="market"
            selected={
              procurement_draft(@form_drafts, @ship.symbol, "recipient_type", "market") == "market"
            }
          >
            Market
          </option>
          <option
            value="contract"
            selected={
              procurement_draft(@form_drafts, @ship.symbol, "recipient_type", "market") == "contract"
            }
          >
            Contract
          </option>
          <option
            value="construction"
            selected={
              procurement_draft(@form_drafts, @ship.symbol, "recipient_type", "market") ==
                "construction"
            }
          >
            Construction
          </option>
        </select>
        <input
          name="contract_id"
          value={procurement_draft(@form_drafts, @ship.symbol, "contract_id", "")}
          placeholder="Contract ID (for contract delivery)"
          class="input input-bordered input-sm"
        />
        <input
          name="construction_system"
          value={procurement_draft(@form_drafts, @ship.symbol, "construction_system", "")}
          placeholder="Construction system"
          class="input input-bordered input-sm font-mono"
        />
        <input
          name="trade_symbol"
          value={procurement_draft(@form_drafts, @ship.symbol, "trade_symbol", "")}
          placeholder="Trade symbol"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="quantity"
          value={procurement_draft(@form_drafts, @ship.symbol, "quantity", "")}
          type="number"
          min="1"
          placeholder="Quantity"
          class="input input-bordered input-sm"
          required
        />
        <input
          name="destination_waypoint"
          value={procurement_draft(@form_drafts, @ship.symbol, "destination_waypoint", "")}
          placeholder="Destination waypoint"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="source_systems"
          value={procurement_draft(@form_drafts, @ship.symbol, "source_systems", "")}
          placeholder="Source systems (comma-separated)"
          class="input input-bordered input-sm font-mono"
        />
        <input
          name="reserve_credits"
          value={procurement_draft(@form_drafts, @ship.symbol, "reserve_credits", "")}
          type="number"
          min="0"
          placeholder="Reserve credits"
          class="input input-bordered input-sm"
        />
        <input
          name="price_ceiling"
          value={procurement_draft(@form_drafts, @ship.symbol, "price_ceiling", "")}
          type="number"
          min="1"
          placeholder="Purchase price ceiling"
          class="input input-bordered input-sm"
        />
        <input
          name="minimum_sale_price"
          value={procurement_draft(@form_drafts, @ship.symbol, "minimum_sale_price", "")}
          type="number"
          min="1"
          placeholder="Minimum sale price"
          class="input input-bordered input-sm"
        />
        <input
          name="minimum_sale_value"
          value={procurement_draft(@form_drafts, @ship.symbol, "minimum_sale_value", "")}
          type="number"
          min="1"
          placeholder="Minimum sale value"
          class="input input-bordered input-sm"
        />
        <label class="label cursor-pointer justify-start gap-2 sm:col-span-2">
          <input
            name="compatible_existing_cargo"
            type="checkbox"
            class="checkbox checkbox-sm"
            checked={
              procurement_draft(@form_drafts, @ship.symbol, "compatible_existing_cargo", nil) in [
                "on",
                "true",
                true
              ]
            }
          />
          <span class="label-text">Use compatible cargo already aboard</span>
        </label>
        <button type="submit" class="btn btn-secondary btn-sm sm:col-span-2">Assign Procurement Job</button>
      </form>
      <div :if={@job} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={Job.running?(@job)}
          type="button"
          phx-click="pause_procurement_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-sm"
        >Pause</button>
        <button
          :if={@job.status in ["paused", "blocked"]}
          type="button"
          phx-click="resume_procurement_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >Resume</button>
        <button
          type="button"
          phx-click="stop_procurement_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-ghost btn-sm"
        >Stop</button>
      </div>
    </section>
    """
  end

  attr :ship, :map, required: true
  attr :form_drafts, :map, default: %{}

  defp construction_supply_job_panel(assigns) do
    job = Map.get(assigns.ship, :job)
    progress = (job && job.progress) || %{}
    assigns = assign(assigns, job: job, progress: progress)

    ~H"""
    <section class="mt-4 rounded border border-secondary/30 p-3" data-job-panel="construction-supply">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">Construction Supply Job</span>
        <span class="badge badge-outline badge-sm" data-construction-supply-job-status>{job_status(
          @job
        )}</span>
      </div>
      <dl :if={@job} class="mt-3 grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
        <div>
          <dt class="opacity-60">Project</dt><dd class="font-mono">
            {@progress["construction_waypoint"]}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Spent</dt><dd>{@progress["spent"] || 0} credits</dd>
        </div>
        <div>
          <dt class="opacity-60">Trips</dt><dd>{@progress["trips"] || 0}</dd>
        </div>
        <div>
          <dt class="opacity-60">Active work</dt><dd>{job_active_work(@job, @ship)}</dd>
        </div>
      </dl>
      <p :if={job_reason(@job)} class="mt-2 text-xs text-error">{job_reason(@job)}</p>
      <form
        :if={is_nil(@job)}
        id={"construction-supply-job-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit="configure_construction_supply_job"
        class="mt-3 grid gap-2 sm:grid-cols-2"
      >
        <input
          type="hidden"
          name="draft_key"
          value={draft_key("construction_supply_job", [@ship.symbol])}
        />
        <input type="hidden" name="ship_symbol" value={@ship.symbol} />
        <input
          name="construction_system"
          value={construction_supply_draft(@form_drafts, @ship.symbol, "construction_system", "")}
          placeholder="Construction system"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="construction_waypoint"
          value={construction_supply_draft(@form_drafts, @ship.symbol, "construction_waypoint", "")}
          placeholder="Construction waypoint"
          class="input input-bordered input-sm font-mono"
          required
        />
        <input
          name="source_systems"
          value={construction_supply_draft(@form_drafts, @ship.symbol, "source_systems", "")}
          placeholder="Source systems (comma-separated)"
          class="input input-bordered input-sm font-mono"
        />
        <input
          name="reserve_credits"
          value={construction_supply_draft(@form_drafts, @ship.symbol, "reserve_credits", "")}
          type="number"
          min="0"
          placeholder="Reserve credits"
          class="input input-bordered input-sm"
        />
        <input
          name="maximum_total_cost"
          value={construction_supply_draft(@form_drafts, @ship.symbol, "maximum_total_cost", "")}
          type="number"
          min="1"
          placeholder="Maximum total cost"
          class="input input-bordered input-sm"
        />
        <label class="label cursor-pointer justify-start gap-2"><input
          name="compatible_existing_cargo"
          type="checkbox"
          class="checkbox checkbox-sm"
          checked={
            construction_supply_draft(@form_drafts, @ship.symbol, "compatible_existing_cargo", nil) in [
              "on",
              "true",
              true
            ]
          }
        /><span class="label-text">Use compatible cargo already aboard</span></label>
        <button type="submit" class="btn btn-secondary btn-sm sm:col-span-2">Assign Construction Supply Job</button>
      </form>
      <div :if={@job} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={Job.running?(@job)}
          type="button"
          phx-click="pause_construction_supply_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-sm"
        >Pause</button>
        <button
          :if={@job.status in ["paused", "blocked"]}
          type="button"
          phx-click="resume_construction_supply_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >Resume</button>
        <button
          type="button"
          phx-click="stop_construction_supply_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-ghost btn-sm"
        >Stop</button>
      </div>
    </section>
    """
  end

  attr :ship, :map, required: true
  attr :form_drafts, :map, default: %{}

  defp outfitting_job_panel(assigns) do
    job = Map.get(assigns.ship, :job)
    progress = (job && job.progress) || %{}
    assigns = assign(assigns, job: job, progress: progress)

    ~H"""
    <section class="mt-4 rounded border border-secondary/30 p-3" data-job-panel="outfitting">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">Ship Outfitting Job</span>
        <span class="badge badge-outline badge-sm" data-outfitting-job-status>{job_status(@job)}</span>
      </div>
      <dl :if={@job} class="mt-3 grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
        <div>
          <dt class="opacity-60">Readiness</dt><dd>{@progress["requested_capability"]}</dd>
        </div>
        <div>
          <dt class="opacity-60">Acceptable modules</dt><dd class="font-mono">
            {Enum.join(@progress["acceptable_modules"] || [], ", ")}
          </dd>
        </div>
        <div :if={@progress["source_system"]}>
          <dt class="opacity-60">Source System</dt><dd class="font-mono">
            {@progress["source_system"]}
          </dd>
        </div>
        <div :if={@progress["source_system"]}>
          <dt class="opacity-60">Source Waypoints</dt><dd class="font-mono">
            {source_waypoint_label(@progress["source_waypoints"])}
          </dd>
        </div>
        <div :if={@progress["source_system"]}>
          <dt class="opacity-60">Spend</dt><dd>
            {@progress["spent"] || 0} / {@progress["maximum_total_cost"]} credits
          </dd>
        </div>
        <div :if={@progress["source_system"]}>
          <dt class="opacity-60">Credit reserve</dt><dd>
            {@progress["reserve_credits"] || 0} credits
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Cargo candidate</dt><dd class="font-mono">
            {@progress["cargo_candidate"] || "none"}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Installed modules</dt><dd class="font-mono">
            {Enum.join(@progress["installed_modules"] || [], ", ")}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Authorized removals</dt><dd class="font-mono">
            {Enum.map_join(@progress["authorized_removals"] || %{}, ", ", fn {symbol, count} ->
              "#{symbol}:#{count}"
            end)}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Active operation</dt><dd class="font-mono">
            {get_in(@progress, ["active_operation", "kind"]) || "none"}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Evidence</dt><dd>
            {(@progress["evidence"] || []) |> length()} observations
          </dd>
        </div>
      </dl>
      <p :if={job_reason(@job)} class="mt-2 text-xs text-error">{job_reason(@job)}</p>
      <form
        :if={is_nil(@job)}
        id={"outfitting-job-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit="configure_outfitting_job"
        class="mt-3 grid gap-2 sm:grid-cols-2"
      >
        <input type="hidden" name="draft_key" value={draft_key("outfitting_job", [@ship.symbol])} />
        <input type="hidden" name="ship_symbol" value={@ship.symbol} />
        <input
          name="requested_capability"
          value={
            draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "requested_capability", "")
          }
          placeholder="Requested readiness capability"
          required
          class="input input-bordered input-sm"
        />
        <input
          name="acceptable_modules"
          value={
            draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "acceptable_modules", "")
          }
          placeholder="Acceptable modules (comma-separated)"
          required
          class="input input-bordered input-sm font-mono"
        />
        <input
          name="authorized_removals"
          value={
            draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "authorized_removals", "")
          }
          placeholder="Authorized removals: MODULE:count"
          class="input input-bordered input-sm font-mono sm:col-span-2"
        />
        <input
          name="source_waypoints"
          value={draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "source_waypoints", "")}
          placeholder="Source Waypoints (optional, comma-separated)"
          class="input input-bordered input-sm font-mono sm:col-span-2"
        />
        <input
          name="reserve_credits"
          value={draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "reserve_credits", "")}
          placeholder="Reserve credits (optional)"
          inputmode="numeric"
          class="input input-bordered input-sm"
        />
        <input
          name="maximum_total_cost"
          value={
            draft_field(@form_drafts, "outfitting_job", [@ship.symbol], "maximum_total_cost", "")
          }
          placeholder="Maximum spend"
          inputmode="numeric"
          required
          class="input input-bordered input-sm"
        />
        <button type="submit" class="btn btn-secondary btn-sm sm:col-span-2">Assign Ship Outfitting Job</button>
      </form>
      <div :if={@job} class="mt-3 flex flex-wrap gap-2">
        <button
          :if={Job.running?(@job)}
          type="button"
          phx-click="pause_outfitting_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-sm"
        >Pause</button>
        <button
          :if={@job.status in ["paused", "blocked"]}
          type="button"
          phx-click="resume_outfitting_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >Resume</button>
        <button
          type="button"
          phx-click="stop_outfitting_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-ghost btn-sm"
        >Stop</button>
      </div>
    </section>
    """
  end

  defp miner_job_panel(assigns) do
    job = Map.get(assigns.ship, :job)
    history = Map.get(assigns.ship, :job_history, [])
    intent_history = Map.get(assigns.ship, :manual_intent_history, [])
    assigns = assign(assigns, job: job, job_history: history, intent_history: intent_history)

    ~H"""
    <div class="mt-4 rounded border border-primary/20 p-3" data-job-panel="miner">
      <div class="flex items-center justify-between gap-2">
        <span class="text-xs font-semibold uppercase tracking-wider opacity-60">Miner Job</span>
        <span class="badge badge-outline badge-sm" data-job-status>
          {job_status(@job)}
        </span>
      </div>
      <dl class="mt-3 grid grid-cols-1 gap-1 text-xs sm:grid-cols-2">
        <div>
          <dt class="opacity-60">Gather mode</dt>
          <dd data-job-gather-mode>
            {gather_mode_label(@job)}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Active work</dt>
          <dd data-job-active-work>
            {job_active_work(@job, @ship)}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Next expected transition</dt>
          <dd data-job-next-transition>
            {job_next_transition(@job, @ship)}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Effective sellable payload</dt>
          <dd data-job-sellable>
            {job_sellable_payload(@job, @ship)}
          </dd>
        </div>
        <div>
          <dt class="opacity-60">Pending delivery</dt>
          <dd data-job-pending-delivery>
            {job_pending_delivery(@job, @ship)}
          </dd>
        </div>
      </dl>
      <p
        :if={job_reason(@job)}
        class="mt-2 text-xs text-error"
        data-job-reason
      >
        {job_reason(@job)}
      </p>
      <form
        id={"miner-job-form-#{@ship.symbol}"}
        phx-change="track_draft"
        phx-submit={if(@job, do: "replace_miner_job", else: "configure_miner_job")}
        class="mt-3 grid gap-2 sm:grid-cols-3"
      >
        <input type="hidden" name="draft_key" value={draft_key("miner_job", [@ship.symbol])} />
        <input type="hidden" name="ship_symbol" value={@ship.symbol} />
        <select
          name="gather_mode"
          class="select select-bordered select-sm"
          aria-label="Gather mode"
        >
          <option
            value="extract"
            selected={gather_mode_selected?(@form_drafts, @job, @ship.symbol, "extract")}
          >
            Extract
          </option>
          <option
            value="siphon"
            selected={gather_mode_selected?(@form_drafts, @job, @ship.symbol, "siphon")}
          >
            Siphon
          </option>
        </select>
        <input
          name="extraction_waypoint"
          value={
            draft_field(
              @form_drafts,
              "miner_job",
              [@ship.symbol],
              "extraction_waypoint",
              @job && @job.extraction_waypoint
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
              "miner_job",
              [@ship.symbol],
              "market_waypoint",
              @job && @job.market_waypoint
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
              "miner_job",
              [@ship.symbol],
              "cargo_threshold",
              @job && @job.cargo_threshold
            )
          }
          type="number"
          min="1"
          placeholder="Cargo threshold"
          class="input input-bordered input-sm"
          required
        />
        <button type="submit" class="btn btn-ghost btn-sm sm:col-span-3">
          {if(@job, do: "Replace Miner Job", else: "Assign Miner Job")}
        </button>
      </form>
      <div class="mt-2 flex flex-wrap gap-2">
        <button
          :if={Job.running?(@job)}
          type="button"
          phx-click="pause_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-warning btn-sm"
        >
          Pause
        </button>
        <button
          :if={
            @job &&
              (@job.status == "paused" or
                 (@job.status == "blocked" and
                    not (match?(%JobBlocker{}, @job.blocker) and is_map(@job.in_flight_action))))
          }
          type="button"
          phx-click="resume_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >
          Resume after revalidation
        </button>
        <button
          :if={
            @job && @job.status == "blocked" && match?(%JobBlocker{}, @job.blocker) &&
              is_map(@job.in_flight_action)
          }
          type="button"
          phx-click="reconcile_miner_job"
          phx-value-symbol={@ship.symbol}
          class="btn btn-primary btn-sm"
        >
          {if(@job.blocker.reason == "retry_exhausted", do: "Reconcile", else: "Reconcile and retry")}
        </button>
        <button
          :if={@job}
          type="button"
          phx-click="stop_miner_job"
          phx-value-symbol={@ship.symbol}
          data-confirm="Stop Miner Job? Terminal history remains available."
          class="btn btn-ghost btn-sm"
        >
          Stop
        </button>
      </div>
      <div :if={@job_history != []} class="mt-3 border-t border-base-300/60 pt-3" data-job-history>
        <p class="text-xs font-semibold uppercase tracking-wider opacity-60">Terminal history</p>
        <ol class="mt-2 space-y-2 text-xs">
          <li :for={historical_job <- @job_history}>
            <details data-job-history-entry={historical_job.id}>
              <summary class="cursor-pointer">
                <span class="font-semibold">{terminal_job_state(historical_job.status)}</span>
                <time class="ml-2 opacity-60">{format_job_finished_at(historical_job.finished_at)}</time>
              </summary>
              <dl class="mt-2 grid gap-1 pl-3 sm:grid-cols-2">
                <div>
                  <dt class="opacity-60">Job</dt><dd>Miner #{historical_job.id}</dd>
                </div>
                <div>
                  <dt class="opacity-60">Gather mode</dt><dd>{gather_mode_label(historical_job)}</dd>
                </div>
                <div class="sm:col-span-2">
                  <dt class="opacity-60">Configured loop</dt>
                  <dd class="font-mono">
                    {historical_job.extraction_waypoint} → {historical_job.market_waypoint}
                  </dd>
                </div>
                <div>
                  <dt class="opacity-60">Cargo threshold</dt><dd>{historical_job.cargo_threshold}</dd>
                </div>
                <div>
                  <dt class="opacity-60">Last result</dt><dd>
                    {terminal_job_result(historical_job)}
                  </dd>
                </div>
                <div>
                  <dt class="opacity-60">Final progress</dt><dd>
                    {format_terminal_value(historical_job.progress)}
                  </dd>
                </div>
                <div :if={historical_job.blocked_reason || historical_job.blocker}>
                  <dt class="opacity-60">Terminal reason</dt><dd>
                    {terminal_job_reason(historical_job)}
                  </dd>
                </div>
                <div
                  :if={historical_job.blocker && historical_job.blocker.evidence}
                  class="sm:col-span-2"
                >
                  <dt class="opacity-60">Decision evidence</dt><dd>
                    {historical_job.blocker.evidence}
                  </dd>
                </div>
                <div :if={historical_job.predecessor_job_id}>
                  <dt class="opacity-60">Predecessor</dt><dd>
                    Miner {historical_job.predecessor_job_id}
                  </dd>
                </div>
                <div :if={historical_job.successor_job_id}>
                  <dt class="opacity-60">Successor</dt><dd>
                    Miner {historical_job.successor_job_id}
                  </dd>
                </div>
              </dl>
            </details>
          </li>
        </ol>
      </div>
      <div
        :if={@intent_history != []}
        class="mt-3 border-t border-base-300/60 pt-3"
        data-manual-intent-history
      >
        <p class="text-xs font-semibold uppercase tracking-wider opacity-60">
          Manual control history
        </p>
        <ol class="mt-2 space-y-2 text-xs">
          <li :for={intent <- @intent_history}>
            <details data-manual-intent-history-entry={intent.id}>
              <summary class="cursor-pointer">
                {manual_intent_status(intent)} {manual_intent_label(intent)}
              </summary>
              <dl class="mt-2 grid gap-1 pl-3 sm:grid-cols-2">
                <div>
                  <dt class="opacity-60">Last result</dt><dd>
                    {format_terminal_value(intent.last_action_result)}
                  </dd>
                </div>
                <div :if={intent.blocker}>
                  <dt class="opacity-60">Decision evidence</dt><dd>
                    {intent.blocker.evidence || blocker_summary(intent.blocker)}
                  </dd>
                </div>
              </dl>
            </details>
          </li>
        </ol>
      </div>
    </div>
    """
  end

  defp activity_panel(assigns) do
    activities =
      assigns.overviews
      |> Enum.flat_map(fn %{activity: activity} -> activity end)
      |> Enum.reject(&activity_noise?/1)
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

  defp gather_mode_label(%{gather_mode: "siphon"}), do: "Siphon"
  defp gather_mode_label(%{gather_mode: "extract"}), do: "Extract"
  defp gather_mode_label(_), do: "Extract"

  defp gather_mode_selected?(drafts, job, ship_symbol, value) do
    draft_field(drafts, "miner_job", [ship_symbol], "gather_mode", job && job.gather_mode) ==
      value
  end

  defp procurement_draft(drafts, ship_symbol, field, fallback),
    do: draft_field(drafts, "procurement_job", [ship_symbol], field, fallback)

  defp construction_supply_draft(drafts, ship_symbol, field, fallback),
    do: draft_field(drafts, "construction_supply_job", [ship_symbol], field, fallback)

  defp job_status(%{status: "blocked"}), do: "Blocked"

  defp job_status(%{status: "paused"}), do: "Paused"
  defp job_status(nil), do: "Manual"
  defp job_status(%{status: "waiting"}), do: "Waiting"
  defp job_status(%{type: "explorer", status: "active"}), do: "Active System Exploration Job"
  defp job_status(%{type: "procurement", status: "active"}), do: "Active Procurement Job"

  defp job_status(%{type: "construction_supply", status: "active"}),
    do: "Active Construction Supply Job"

  defp job_status(%{type: "market_trading", status: "active"}),
    do: "Active Market Trading Job"

  defp job_status(%{status: "active"}), do: "Active Miner Job"
  defp job_status(_), do: "Manual"

  defp terminal_job_state("completed"), do: "Completed"
  defp terminal_job_state("failed"), do: "Failed"
  defp terminal_job_state("stopped"), do: "Stopped"
  defp terminal_job_state("replaced"), do: "Replaced"

  defp format_job_finished_at(%DateTime{} = finished_at),
    do: Calendar.strftime(finished_at, "%Y-%m-%d %H:%M UTC")

  defp format_job_finished_at(_), do: ""

  defp terminal_job_result(%{last_action_result: %{"kind" => kind}}), do: job_action_label(kind)
  defp terminal_job_result(_), do: "No completed action recorded"

  defp terminal_job_reason(%{blocker: %JobBlocker{} = blocker}), do: blocker_summary(blocker)

  defp terminal_job_reason(%{blocked_reason: reason}) when is_binary(reason),
    do: job_blocked_reason(reason)

  defp terminal_job_reason(_), do: "No terminal reason recorded"

  defp format_terminal_value(value) when value in [nil, %{}], do: "None recorded"
  defp format_terminal_value(value), do: inspect(value)

  defp job_reason(%{
         status: "blocked",
         blocker: %JobBlocker{
           reason: reason,
           resolver: resolver,
           retry_condition: retry_condition,
           corrective_actions: actions
         }
       }) do
    "Blocked: #{reason}. Resolver: #{resolver}; retry: #{retry_condition}; actions: #{Enum.join(actions, ", ")}"
  end

  defp job_reason(%{status: "blocked", blocked_reason: reason}) when is_binary(reason),
    do: "Blocked: #{job_blocked_reason(reason)}"

  defp job_reason(%{status: "paused", blocked_reason: reason}) when is_binary(reason),
    do: reason

  defp job_reason(_), do: nil

  defp manual_intent_status(%{status: "active"}), do: "Working"
  defp manual_intent_status(%{status: "waiting"}), do: "Waiting"
  defp manual_intent_status(%{status: "blocked"}), do: "Blocked"
  defp manual_intent_status(%{status: "completed"}), do: "Completed"
  defp manual_intent_status(%{status: "stopped"}), do: "Stopped"
  defp manual_intent_status(_), do: "Manual"

  defp manual_intent_label(%{type: "buy", parameters: parameters, target_waypoint: waypoint}),
    do: "Buy #{parameters["trade_symbol"]} at #{waypoint}"

  defp manual_intent_label(%{type: "sell", parameters: parameters, target_waypoint: waypoint}),
    do: "Sell #{parameters["trade_symbol"]} at #{waypoint}"

  defp manual_intent_label(%{type: "deliver", parameters: parameters, target_waypoint: waypoint}),
    do: "Deliver #{parameters["trade_symbol"]} at #{waypoint}"

  defp manual_intent_label(%{type: "install_module", parameters: parameters}),
    do: "Install #{parameters["module_symbol"]}"

  defp manual_intent_label(%{type: "remove_module", parameters: parameters}),
    do: "Remove #{parameters["module_symbol"]}"

  defp manual_intent_label(%{target_waypoint: waypoint}), do: "Navigate to #{waypoint}"

  defp module_slots(%{frame: %{module_slots: slots}}) when is_integer(slots), do: slots
  defp module_slots(_ship), do: "?"

  defp manual_intent_status_class(%{status: "waiting"}),
    do: "badge badge-warning badge-sm ml-2"

  defp manual_intent_status_class(%{status: "blocked"}),
    do: "badge badge-error badge-sm ml-2"

  defp manual_intent_status_class(_), do: "badge badge-info badge-sm ml-2"

  defp manual_intent_reason(%{status: "blocked", blocker: %JobBlocker{} = blocker}),
    do: blocker_summary(blocker)

  defp manual_intent_reason(_intent), do: nil

  defp blocker_summary(%JobBlocker{
         reason: reason,
         resolver: resolver,
         retry_condition: retry_condition
       }),
       do:
         "#{job_blocker_correction(reason)}. Resolver: #{resolver}; retry when #{retry_condition}."

  defp blocker_summary(_blocker), do: "Check Activity for details."

  defp job_active_work(
         %{status: "waiting", in_flight_action: %{"kind" => kind}},
         _ship
       )
       when kind in @gather_kinds,
       do: "Waiting for cooldown"

  defp job_active_work(
         %{status: "waiting", in_flight_action: %{"kind" => "navigate"}},
         _ship
       ),
       do: "Traveling to configured waypoint"

  defp job_active_work(
         %{status: "waiting", in_flight_action: %{"kind" => "cooldown"}},
         _ship
       ),
       do: "Waiting for cooldown"

  defp job_active_work(
         %{status: "active", in_flight_action: %{"kind" => "deliver"}},
         _ship
       ),
       do: "Delivering contract cargo"

  defp job_active_work(%{status: "active", in_flight_action: %{"kind" => kind}}, _ship),
    do: "Revalidating #{job_action_label(kind)}"

  defp job_active_work(%{status: "blocked"}, _ship), do: "Blocked"

  defp job_active_work(%{status: "paused", blocked_reason: reason}, _ship),
    do: paused_status(reason)

  defp job_active_work(%{status: "paused"}, _ship), do: "Paused by manual action"
  defp job_active_work(%{status: "active"}, _ship), do: "Evaluating cargo"
  defp job_active_work(_, _ship), do: "Manual"

  defp job_next_transition(
         %{status: "waiting", in_flight_action: %{"kind" => "navigate", "waypoint" => waypoint}},
         _ship
       ),
       do: "Continue at #{waypoint}"

  defp job_next_transition(%{status: "waiting"}, ship) do
    case cooldown_label(ship, 0) do
      "Ready" -> "Reconcile ship"
      label -> "Wait through #{label}"
    end
  end

  defp job_next_transition(%{status: "active", in_flight_action: %{"kind" => kind}}, _ship),
    do: "Continue #{job_action_label(kind)} recovery"

  defp job_next_transition(%{status: "blocked", blocker: %JobBlocker{reason: reason}}, _ship),
    do: "#{job_blocker_correction(reason)}, then Resume"

  defp job_next_transition(%{status: "blocked", blocked_reason: reason}, _ship),
    do: "#{job_correction(reason)}, then Resume"

  defp job_next_transition(%{status: "paused"}, _ship), do: "Resume after revalidation"

  defp job_next_transition(%{status: "active", extraction_waypoint: waypoint}, ship) do
    if cooldown_display_active?(ship),
      do: "Wait through #{cooldown_label(ship, 0)}",
      else: "Evaluate at #{waypoint}"
  end

  defp job_next_transition(_, _ship), do: "Assign Miner Job"

  defp job_sellable_payload(nil, ship), do: "#{cargo_units(ship.cargo)} total units"

  defp job_sellable_payload(%{cargo_threshold: threshold, sellable_goods: goods}, ship)
       when is_list(goods) and goods != [] do
    "#{sellable_units_in(ship, MapSet.new(goods))} / #{threshold} sellable units"
  end

  defp job_sellable_payload(%{cargo_threshold: threshold}, ship) do
    "#{cargo_units(ship.cargo)} / #{threshold} total units"
  end

  defp sellable_units_in(%{cargo: %{inventory: inventory}}, accepted) do
    Enum.reduce(inventory || [], 0, fn item, acc ->
      if MapSet.member?(accepted, item.symbol), do: acc + item.units, else: acc
    end)
  end

  defp sellable_units_in(_ship, _accepted), do: 0

  defp job_pending_delivery(nil, _ship), do: "—"

  defp job_pending_delivery(%{status: "paused"}, _ship), do: "—"

  defp job_pending_delivery(%{contract_deliverables: entries}, %{
         nav: %{waypoint_symbol: waypoint}
       })
       when is_list(entries) and entries != [] do
    case Contracts.pending_deliverables(entries, waypoint) do
      [] ->
        "—"

      pending ->
        pending
        |> Enum.map(fn entry ->
          "#{entry["trade_symbol"]} #{entry["units_remaining"]} due here"
        end)
        |> Enum.join(", ")
    end
  end

  defp job_pending_delivery(_job, _ship), do: "—"

  defp job_blocked_reason(":invalid_extraction_waypoint"),
    do: "Choose an ASTEROID_FIELD or ENGINEERED_ASTEROID extraction waypoint."

  defp job_blocked_reason(":invalid_siphon_waypoint"),
    do: "Choose a GAS_GIANT siphon waypoint."

  defp job_blocked_reason(":siphon_capability_missing"),
    do: "This Ship needs a gas siphon mount and gas processor."

  defp job_blocked_reason(":invalid_market_waypoint"),
    do: "Choose a waypoint with a MARKETPLACE trait."

  defp job_blocked_reason(":cargo_threshold_exceeds_capacity"),
    do: "Cargo threshold exceeds this Ship's capacity."

  defp job_blocked_reason(":mining_capability_missing"),
    do: "This Ship has no mining laser installed."

  defp job_blocked_reason(reason) when is_binary(reason) do
    if String.starts_with?(reason, [":", "{", "%"]) do
      "A Miner Job action could not be completed."
    else
      reason
    end
  end

  defp job_correction(":" <> reason), do: job_blocker_correction(reason)
  defp job_correction(reason), do: job_blocker_correction(reason)

  defp job_blocker_correction("invalid_extraction_waypoint"),
    do: "Choose an asteroid extraction waypoint"

  defp job_blocker_correction("invalid_siphon_waypoint"), do: "Choose a gas giant siphon waypoint"
  defp job_blocker_correction("siphon_capability_missing"), do: "Use a Ship with a gas siphon"
  defp job_blocker_correction("invalid_market_waypoint"), do: "Choose a marketplace waypoint"

  defp job_blocker_correction("cargo_threshold_exceeds_capacity"),
    do: "Lower the cargo threshold"

  defp job_blocker_correction("mining_capability_missing"), do: "Use a Ship with a mining laser"

  defp job_blocker_correction("insufficient_fuel"),
    do: "Refuel the Ship, then issue Navigate again"

  defp job_blocker_correction("outside_system"),
    do: "Cross-System travel is not available yet; choose a Waypoint in this System"

  defp job_blocker_correction("unreadable_arrival"), do: "Reconcile the Ship from game state"
  defp job_blocker_correction(_reason), do: "Check the Job Activity"

  defp job_action_label("navigate"), do: "navigation"
  defp job_action_label("extract"), do: "extraction"
  defp job_action_label("siphon"), do: "siphoning"
  defp job_action_label("sell"), do: "sale"
  defp job_action_label("deliver"), do: "delivery"
  defp job_action_label("jettison"), do: "jettison"
  defp job_action_label("refuel"), do: "refueling"
  defp job_action_label(_kind), do: "Job work"

  defp paused_status("Paused by a direct Ship action"), do: "Paused by manual action"
  defp paused_status("Paused by Operator"), do: "Paused by Operator"
  defp paused_status(nil), do: "Paused by manual action"
  defp paused_status(reason) when is_binary(reason), do: reason
  defp paused_status(_), do: "Paused"

  defp attention_count({:ok, ships}), do: Enum.count(ships, &needs_attention?/1)
  defp attention_count(_), do: 0

  defp fleet_healthy?({:ok, ships}), do: ships != [] and attention_count({:ok, ships}) == 0
  defp fleet_healthy?(_), do: false

  defp operations_class(true), do: ""
  defp operations_class(false), do: "hidden"

  defp needs_attention?(%{job: %{status: "blocked"}}), do: true
  defp needs_attention?(%{job: %{status: "paused"}}), do: true
  defp needs_attention?(%{manual_intent: %{status: "blocked"}}), do: true
  defp needs_attention?(%{nav: %{status: "IN_TRANSIT"}}), do: false
  defp needs_attention?(_), do: false

  defp attention_summary(%{manual_intent: %{status: "blocked"} = intent}),
    do: manual_intent_reason(intent) || manual_intent_status(intent)

  defp attention_summary(%{job: job}) when not is_nil(job), do: job_reason(job) || job_status(job)

  defp attention_summary(%{manual_intent: intent}),
    do: manual_intent_reason(intent) || manual_intent_status(intent)

  defp attention_summary(_), do: "Review Ship state"

  defp activity_noise?(%{kind: kind}) when kind in ["retry", "manual_intent_waiting"], do: true

  defp activity_noise?(%{kind: kind, message: message})
       when kind in ["manual_intent_recovery", "miner_job_recovery"] do
    String.contains?(String.downcase(message), "retrying")
  end

  defp activity_noise?(_), do: false

  defp activity_facts(%{metadata: metadata}) when is_map(metadata) do
    metadata
    |> Enum.filter(fn {key, _value} ->
      key in [
        "outcome",
        "delta",
        "wait",
        "retry",
        "block",
        "recovery",
        "jettison",
        "deliver",
        "remaining"
      ]
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
  defp live_error(:ship_not_in_orbit), do: "This action requires the Ship to be in orbit."
  defp live_error(:ship_not_docked), do: "This action requires the Ship to be docked."
  defp live_error(:cargo_missing), do: "This Ship does not carry that trade good."
  defp live_error(:cargo_full), do: "This Ship has no cargo space available."
  defp live_error(:transfer_same_ship), do: "Choose a different receiving Ship."
  defp live_error(:transfer_waypoint_mismatch), do: "Both Ships must be at the same waypoint."
  defp live_error(:transfer_state_mismatch), do: "Both Ships must be docked or both in orbit."

  defp live_error(:transfer_cargo_missing),
    do: "The transferring Ship does not carry enough cargo."

  defp live_error(:transfer_target_cargo_full),
    do: "The receiving Ship does not have enough cargo space."

  defp live_error(:trade_unavailable), do: "This Market does not sell that trade good."
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
  defp live_error(:miner_job_not_configured), do: "Save a Miner Job configuration first."

  defp live_error(:explorer_job_not_configured),
    do: "Save a System Exploration Job configuration first."

  defp live_error(:source_market_unavailable),
    do: "Procurement Job blocked: no source market is available in the current system."

  defp live_error(:manual_intent_active),
    do: "A manual Navigate is still active for this Ship; stop it before resuming the Job."

  defp live_error(:manual_intent_not_active), do: "There is no manual Navigate to stop."

  defp live_error(:manual_intent_conflict),
    do: "Another manual Navigate was just issued for this Ship; try again."

  defp live_error(:invalid_waypoint), do: "Enter a target waypoint."
  defp live_error(:invalid_module_intent), do: "Choose a module with exact removal authorization."

  defp live_error(:manual_intent_reconciliation_required),
    do: "The prior module operation is still being reconciled from the game."

  defp live_error({:miner_job_blocked, reason}), do: "Miner Job blocked: #{live_error(reason)}"
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

  defp ship_action_state(ship, action), do: Map.get(ship.actions || %{}, action)

  defp cooldown_display_active?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds) and seconds > 0,
       do: true

  defp cooldown_display_active?(_), do: false

  defp trade_action(ship, trade_symbol, action) do
    ship
    |> Map.get(:trade_actions, %{})
    |> Map.get(trade_symbol, %{})
    |> Map.get(action)
  end

  defp action_allowed?(%{allowed?: allowed?}), do: allowed?
  defp action_allowed?(_), do: false

  defp action_reason(%{reason: nil}), do: nil
  defp action_reason(%{reason: reason}), do: live_error(reason)
  defp action_reason(_), do: nil

  attr :reason, :string, default: nil
  slot :inner_block, required: true

  defp action_tooltip(assigns) do
    ~H"""
    <span
      class={if @reason, do: "tooltip tooltip-top", else: "inline-flex"}
      data-tip={@reason}
      tabindex={if @reason, do: "0", else: nil}
      aria-label={if @reason, do: "Unavailable: #{@reason}", else: nil}
    >
      {render_slot(@inner_block)}
    </span>
    """
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

  defp fuel_consumed_label(%{fuel: %{consumed: %{amount: amount}}}) when is_integer(amount),
    do: "#{amount} fuel"

  defp fuel_consumed_label(_), do: "—"

  defp market_has_fuel?(market) do
    Enum.any?([market.exports, market.exchange], fn goods ->
      Enum.any?(goods || [], &(&1.symbol == "FUEL"))
    end)
  end

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

  defp construction_delivery_ships({:ok, ships}, destination) when is_list(ships) do
    Enum.filter(ships, fn ship ->
      not in_transit?(ship) and ship_location(ship) == destination and cargo_units(ship.cargo) > 0
    end)
  end

  defp construction_delivery_ships(_, _), do: []

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

  defp transfer_targets(ship, ships) do
    Enum.filter(ships, &transfer_target?(ship, &1))
  end

  defp transfer_target?(%{symbol: source}, %{symbol: source}), do: false

  defp transfer_target?(%{nav: %{waypoint_symbol: waypoint, status: status}}, %{
         nav: %{waypoint_symbol: waypoint, status: status}
       })
       when status in ["DOCKED", "IN_ORBIT"],
       do: true

  defp transfer_target?(_, _), do: false

  defp transfer_target(ship, ships),
    do: transfer_targets(ship, ships) |> List.first() |> then(&(&1 && &1.symbol))

  defp transfer_symbol(ship),
    do: cargo_inventory(ship) |> List.first() |> then(&(&1 && &1.symbol))

  defp transfer_symbol(ship, drafts),
    do: draft_field(drafts, "transfer", [ship.symbol], "trade_symbol", transfer_symbol(ship))

  defp transfer_item(ship, drafts), do: cargo_item(ship, transfer_symbol(ship, drafts))

  defp cargo_name(%{name: name}) when is_binary(name) and name != "", do: name
  defp cargo_name(_), do: nil

  defp cargo_description(%{description: description})
       when is_binary(description) and description != "",
       do: description

  defp cargo_description(_), do: nil

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
