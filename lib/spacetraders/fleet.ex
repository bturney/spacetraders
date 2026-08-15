defmodule SpaceTraders.Fleet do
  @moduledoc """
  The Fleet context: the ships an Agent owns and their live state.

  A ship's live state — location, fuel, cargo, cooldown, nav status — is pulled
  from the game through `SpaceTraders.API`. The server is the source of truth;
  the local `ships` table is the app's registry of owned ships (seeded with the
  starter fleet) and carries no live state. The dashboard reads the live fleet
  through this context so it stays a thin consumer with no game logic of its own.

  Ship actions here orchestrate the game call and the app's async model: after a
  successful navigate the pending arrival is persisted to the timeline and armed
  on the ship's GenServer, so the ship stays busy until it actually arrives
  (ADR 0005).
  """

  import Ecto.Query, warn: false
  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model.{ShipNav, ShipNavRoute}
  alias SpaceTraders.Fleet.{Activity, AutopilotConfig, Ship, ShipDestination}
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Listing, Shipyard}
  alias SpaceTraders.Timeline

  @doc """
  Pulls the agent's live fleet from the game API.

  Each ship carries its current nav (location + docked/orbiting/transit state),
  fuel, cargo and cooldown — the data the fleet cards render.

  Returns `{:ok, [%SpaceTraders.API.Model.Ship{}]}` or an API error. An agent
  without a stored AgentToken returns `{:error, :agent_token_missing}`.
  """
  def list_ships(%AgentRecord{agent_token: agent_token})
      when is_binary(agent_token) and agent_token != "" do
    SpaceTraders.API.get_ships(agent_token)
  end

  def list_ships(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc """
  Reads everything the Fleet command panel displays for an Agent.

  Each live read remains independent: an unavailable Agent overview or Shipyard
  does not hide the rest of the Agent's Fleet. The game remains the source of
  truth, so every call assembles fresh data.
  """
  def command_snapshot(%AgentRecord{} = agent) do
    overview = Agent.agent_overview(agent)
    ships = list_ships(agent) |> annotate_autopilot(agent)
    ships = annotate_actions(ships)
    waypoints = list_waypoints(agent)
    listings = snapshot_listings(agent, ships, waypoints) |> annotate_listing_actions(overview)

    %{
      agent: agent,
      overview: overview,
      ships: ships,
      contracts: Contracts.list_contracts(agent),
      shipyards: listings.shipyards,
      markets: listings.markets,
      waypoints: waypoints,
      activity: recent_activity(agent)
    }
  end

  @doc "Reads Market data for a selected Waypoint when it is a Marketplace."
  def waypoint_market(%AgentRecord{agent_token: token}, waypoint)
      when is_binary(token) and token != "" do
    with :ok <- market_waypoint?(waypoint),
         %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      SpaceTraders.API.get_market(token, system, symbol)
    else
      {:error, :invalid_market_waypoint} -> :not_a_marketplace
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_market(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Returns the ten most recent local events for an Agent, newest first."
  def recent_activity(%AgentRecord{} = agent) do
    Activity
    |> where([a], a.agent_id == ^agent.id)
    |> order_by([a], desc: a.inserted_at)
    |> limit(10)
    |> preload(:ship)
    |> Repo.all()
  end

  defp annotate_autopilot({:ok, ships}, agent) do
    {:ok,
     Enum.map(ships, fn ship ->
       ensure_ship_record(agent, ship)

       ship
       |> Map.put(:autopilot, autopilot_config(agent, ship.symbol))
       |> Map.put(:destination_history, destination_history(agent, ship.symbol))
     end)}
  end

  defp annotate_autopilot(result, _agent), do: result

  defp annotate_actions({:ok, ships}) do
    {:ok, Enum.map(ships, &Map.put(&1, :actions, ship_actions(&1)))}
  end

  defp annotate_actions(result), do: result

  defp ship_actions(ship) do
    cooldown = cooldown_active?(ship)
    status = ship_status(ship)

    %{
      navigate:
        action_state(
          not cooldown and status != "IN_TRANSIT",
          cooldown_reason(cooldown, :ship_in_transit)
        ),
      dock:
        action_state(
          not cooldown and status == "IN_ORBIT",
          cooldown_reason(cooldown, :ship_not_in_orbit)
        ),
      orbit:
        action_state(
          not cooldown and status == "DOCKED",
          cooldown_reason(cooldown, :ship_not_docked)
        ),
      extract:
        action_state(
          not cooldown and status == "IN_ORBIT",
          cooldown_reason(cooldown, :ship_not_in_orbit)
        ),
      siphon:
        action_state(
          not cooldown and status == "IN_ORBIT" and match?(:ok, siphon_capability?(ship)),
          siphon_reason(cooldown, status, ship)
        ),
      refuel:
        action_state(
          not cooldown and status == "DOCKED",
          cooldown_reason(cooldown, :ship_not_docked)
        )
    }
  end

  defp ship_status(%{nav: %{status: status}}) when is_binary(status), do: status
  defp ship_status(_), do: "UNKNOWN"

  defp cooldown_reason(true, _reason), do: :cooldown_active
  defp cooldown_reason(false, reason), do: reason

  defp siphon_reason(true, _status, _ship), do: :cooldown_active

  defp siphon_reason(false, "IN_ORBIT", ship) do
    case siphon_capability?(ship) do
      :ok -> nil
      {:error, reason} -> reason
    end
  end

  defp siphon_reason(false, _status, _ship), do: :ship_not_in_orbit

  defp action_state(true, _reason), do: %{allowed?: true, reason: nil}
  defp action_state(false, reason), do: %{allowed?: false, reason: reason}

  defp ensure_ship_record(agent, %{symbol: symbol}) do
    if is_nil(Repo.get_by(Ship, agent_id: agent.id, symbol: symbol)) do
      record_ship(agent, symbol, "UNKNOWN")
    end

    :ok
  end

  @doc "Saves a Ship's loop configuration without enabling Autopilot."
  def configure_autopilot(%AgentRecord{} = agent, ship_symbol, attrs) when is_map(attrs) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         :ok <- preempt_autopilot(agent, ship, :configuration_changed),
         {:ok, config} <- upsert_autopilot(ship, attrs) do
      record_activity(agent, ship, "configuration", "Autopilot configuration changed")
      {:ok, config}
    end
  end

  @doc "Pauses an active Autopilot while retaining its configuration."
  def pause_autopilot(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %AutopilotConfig{} = config <- Repo.get_by(AutopilotConfig, ship_id: ship.id) do
      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "manual",
            status: "paused",
            in_flight_action: nil
          )
        )

      record_activity(agent, ship, "pause", "Autopilot paused by Operator")
      {:ok, config}
    else
      nil -> {:error, :autopilot_not_configured}
      error -> error
    end
  end

  @doc "Resumes an Autopilot only after a complete authoritative validation."
  def resume_autopilot(%AgentRecord{} = agent, ship_symbol),
    do: start_autopilot(agent, ship_symbol)

  @doc "Stops Autopilot, cancels pending work, and removes its saved configuration."
  def stop_autopilot(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol) do
      Repo.delete_all(from c in AutopilotConfig, where: c.ship_id == ^ship.id)
      record_activity(agent, ship, "stop", "Autopilot stopped; Ship returned to Manual")
      :ok
    end
  end

  @doc "Returns the persisted Autopilot configuration for a Ship, or nil."
  def autopilot_config(%AgentRecord{} = agent, ship_symbol) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} -> Repo.get_by(AutopilotConfig, ship_id: ship.id)
      _ -> nil
    end
  end

  @doc "Explicitly starts a configured Autopilot after authoritative validation."
  def start_autopilot(%AgentRecord{} = agent, ship_symbol) do
    with {:ok, ship} <- owned_ship(agent, ship_symbol),
         %AutopilotConfig{} = config <- Repo.get_by(AutopilotConfig, ship_id: ship.id),
         {:ok, live_ship} <- validate_autopilot(agent, ship, config) do
      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "autopilot",
            status: "ready",
            blocked_reason: nil,
            last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
          )
        )

      case advance_autopilot(agent, config, live_ship) do
        {:ok, config} -> {:ok, config}
        {:error, reason} -> {:error, {:autopilot_blocked, reason}}
      end
    else
      nil -> {:error, :autopilot_not_configured}
      {:error, reason} -> block_autopilot(agent, ship_symbol, reason)
    end
  end

  defp owned_ship(agent, symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
      nil -> {:error, :ship_not_owned}
      ship -> {:ok, ship}
    end
  end

  defp upsert_autopilot(ship, attrs) do
    config = Repo.get_by(AutopilotConfig, ship_id: ship.id) || %AutopilotConfig{ship_id: ship.id}

    config
    |> AutopilotConfig.changeset(attrs)
    |> Ecto.Changeset.put_change(:desired_mode, "manual")
    |> Ecto.Changeset.put_change(:status, "ready")
    |> Ecto.Changeset.put_change(:blocked_reason, nil)
    |> Repo.insert_or_update()
  end

  defp preempt_autopilot(agent, ship, reason) do
    case Repo.get_by(AutopilotConfig, ship_id: ship.id) do
      %AutopilotConfig{desired_mode: "autopilot"} = config ->
        Repo.update!(
          Ecto.Changeset.change(config,
            desired_mode: "manual",
            status: "paused",
            in_flight_action: nil
          )
        )

        record_activity(agent, ship, "manual_override", "Autopilot preempted: #{reason}")
        :ok

      _ ->
        :ok
    end
  end

  defp preempt_autopilot_for(agent, ship_symbol, reason) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      %Ship{} = ship -> preempt_autopilot(agent, ship, reason)
      nil -> :ok
    end
  end

  defp record_activity(agent, ship, kind, message, metadata \\ %{}) do
    Repo.insert!(%Activity{
      agent_id: agent.id,
      ship_id: ship.id,
      kind: kind,
      message: message,
      metadata: metadata
    })

    :ok
  end

  defp validate_autopilot(%AgentRecord{agent_token: token}, ship, config)
       when is_binary(token) and token != "" do
    with {:ok, live_ship} <- SpaceTraders.API.get_ship(token, ship.symbol),
         {:ok, extraction} <-
           waypoint(token, live_ship.nav.system_symbol, config.extraction_waypoint),
         :ok <- extraction_waypoint?(extraction),
         {:ok, market_waypoint} <-
           waypoint(token, live_ship.nav.system_symbol, config.market_waypoint),
         :ok <- market_waypoint?(market_waypoint),
         {:ok, market} <-
           SpaceTraders.API.get_market(token, live_ship.nav.system_symbol, config.market_waypoint),
         :ok <- market_available?(market),
         :ok <- cargo_policy?(live_ship, config.cargo_threshold),
         :ok <- mining_capability?(live_ship) do
      {:ok, live_ship}
    end
  end

  defp validate_autopilot(_, _, _), do: {:error, :agent_token_missing}

  defp waypoint(token, system, symbol), do: SpaceTraders.API.get_waypoint(token, system, symbol)

  defp extraction_waypoint?(%{type: type}) when type in ["ASTEROID_FIELD", "ENGINEERED_ASTEROID"],
    do: :ok

  defp extraction_waypoint?(_), do: {:error, :invalid_extraction_waypoint}

  defp market_waypoint?(%{traits: traits}) do
    if Enum.any?(traits || [], &(&1.symbol == "MARKETPLACE")),
      do: :ok,
      else: {:error, :invalid_market_waypoint}
  end

  defp market_waypoint?(_), do: {:error, :invalid_market_waypoint}
  defp market_available?(%{symbol: symbol}) when is_binary(symbol), do: :ok
  defp market_available?(_), do: {:error, :market_unavailable}

  defp cargo_policy?(%{cargo: %{capacity: capacity}}, threshold) when threshold <= capacity,
    do: :ok

  defp cargo_policy?(_, _), do: {:error, :cargo_threshold_exceeds_capacity}

  defp mining_capability?(%{mounts: mounts}) do
    if Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_MINING_LASER")),
      do: :ok,
      else: {:error, :mining_capability_missing}
  end

  defp mining_capability?(_), do: {:error, :mining_capability_missing}

  defp block_autopilot(agent, ship_symbol, reason) do
    case owned_ship(agent, ship_symbol) do
      {:ok, ship} ->
        case Repo.get_by(AutopilotConfig, ship_id: ship.id) do
          %AutopilotConfig{} = config ->
            Repo.update!(
              Ecto.Changeset.change(config,
                desired_mode: "autopilot",
                status: "blocked",
                blocked_reason: inspect(reason)
              )
            )

            {:error, {:autopilot_blocked, reason}}

          nil ->
            {:error, :autopilot_not_configured}
        end

      error ->
        error
    end
  end

  @doc "Reconciles a ready Autopilot and dispatches its next loop leg."
  def advance_autopilot(%AgentRecord{} = agent, %AutopilotConfig{} = config, live_ship) do
    advance_autopilot(agent, config, live_ship, :normal)
  end

  defp advance_autopilot(%AgentRecord{} = agent, %AutopilotConfig{} = config, live_ship, mode) do
    cond do
      in_flight_arrival?(config, live_ship) ->
        maybe_schedule_arrival(agent, live_ship.symbol, %{nav: live_ship.nav})
        {:ok, Repo.update!(Ecto.Changeset.change(config, status: "waiting"))}

      pending_navigation?(config) ->
        {:ok, config}

      at_extraction_waypoint?(live_ship, config.extraction_waypoint) ->
        extract_if_below_threshold(agent, config, live_ship, mode)

      at_market_waypoint?(live_ship, config.market_waypoint) and market_leg?(config) ->
        sell_at_market(agent, config, live_ship)

      true ->
        navigate_autopilot(agent, config, live_ship, config.extraction_waypoint)
    end
  end

  @doc "Marks an Autopilot extraction complete after authoritative cooldown revalidation."
  def revalidate_autopilot_cooldown(agent_id, ship_symbol, live_ship) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %AutopilotConfig{} = config <- Repo.get_by(AutopilotConfig, ship_id: ship.id),
         true <- config.desired_mode == "autopilot",
         true <- cooldown_ready?(live_ship),
         %AgentRecord{} = agent <- Repo.get(AgentRecord, agent_id) do
      case config.in_flight_action do
        %{"kind" => "extract"} ->
          config =
            Repo.update!(
              Ecto.Changeset.change(config,
                status: "ready",
                in_flight_action: nil,
                progress: Map.merge(config.progress || %{}, %{"last_completed" => "extract"})
              )
            )

          advance_autopilot(agent, config, live_ship, :timeline)

        %{"kind" => "cooldown"} ->
          config =
            Repo.update!(Ecto.Changeset.change(config, status: "ready", in_flight_action: nil))

          advance_autopilot(agent, config, live_ship, :timeline)

        _ ->
          :ok
      end
    else
      _ -> :ok
    end
  end

  @doc "Marks an Autopilot navigation attempt complete after authoritative Arrival revalidation."
  def revalidate_autopilot_arrival(agent_id, ship_symbol, live_ship) do
    with %Ship{} = ship <- Repo.get_by(Ship, agent_id: agent_id, symbol: ship_symbol),
         %AutopilotConfig{} = config <- Repo.get_by(AutopilotConfig, ship_id: ship.id),
         true <- config.desired_mode == "autopilot",
         true <- arrived_at_configured_waypoint?(live_ship, config) do
      agent = Repo.get!(AgentRecord, agent_id)
      waypoint = get_in(config.in_flight_action, ["waypoint"])

      config =
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "ready",
            in_flight_action: nil,
            progress: %{"waypoint" => waypoint, "last_completed" => "navigate"}
          )
        )

      advance_autopilot(agent, config, live_ship, :timeline)
    else
      _ -> :ok
    end
  end

  defp at_extraction_waypoint?(
         %{nav: %{status: status, waypoint_symbol: waypoint}},
         extraction_waypoint
       )
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == extraction_waypoint

  defp at_extraction_waypoint?(_, _), do: false

  defp at_market_waypoint?(
         %{nav: %{status: status, waypoint_symbol: waypoint}},
         market_waypoint
       )
       when status in ["DOCKED", "IN_ORBIT"],
       do: waypoint == market_waypoint

  defp at_market_waypoint?(_, _), do: false

  defp arrived_at_configured_waypoint?(live_ship, %AutopilotConfig{
         in_flight_action: %{"waypoint" => waypoint}
       }) do
    at_extraction_waypoint?(live_ship, waypoint) or at_market_waypoint?(live_ship, waypoint)
  end

  defp arrived_at_configured_waypoint?(_, _), do: false

  defp extract_if_below_threshold(agent, config, live_ship, mode) do
    cond do
      live_ship.nav.status == "DOCKED" ->
        case SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol) do
          {:ok, result} -> advance_autopilot(agent, config, %{live_ship | nav: result.nav}, mode)
          {:error, reason} -> mark_autopilot_blocked(config, reason)
        end

      cooldown_active?(live_ship) ->
        maybe_schedule_live_cooldown(agent, live_ship)

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(config,
             status: "waiting",
             in_flight_action: %{"kind" => "cooldown", "waypoint" => config.extraction_waypoint}
           )
         )}

      cargo_units(live_ship) < config.cargo_threshold ->
        action = %{
          "kind" => "extract",
          "waypoint" => config.extraction_waypoint,
          "expected" => %{"cargo_units_at_least" => cargo_units(live_ship) + 1}
        }

        config =
          Repo.update!(
            Ecto.Changeset.change(config, status: "revalidating", in_flight_action: action)
          )

        extract =
          case mode do
            :timeline -> &extract_resources_for_autopilot/2
            :normal -> &extract_resources/2
          end

        case extract.(agent, live_ship.symbol) do
          {:ok, result} ->
            result_snapshot = %{
              "kind" => "extract",
              "yield" => extraction_yield(result)
            }

            {:ok,
             Repo.update!(
               Ecto.Changeset.change(config,
                 status: "waiting",
                 last_action_result: result_snapshot
               )
             )}

          {:error, reason} ->
            Repo.update!(
              Ecto.Changeset.change(config, status: "blocked", blocked_reason: inspect(reason))
            )

            {:error, reason}
        end

      true ->
        navigate_autopilot(agent, config, live_ship, config.market_waypoint)
    end
  end

  defp sell_at_market(%AgentRecord{agent_token: token} = agent, config, live_ship)
       when is_binary(token) and token != "" do
    with {:ok, live_ship} <- dock_for_market(agent, live_ship),
         {:ok, market} <-
           SpaceTraders.API.get_market(
             token,
             live_ship.nav.system_symbol,
             config.market_waypoint
           ),
         {:ok, live_ship} <- settle_market_cargo(agent, config, live_ship, market),
         {:ok, live_ship} <- refuel_for_market_departure(agent, config, live_ship, market) do
      navigate_autopilot(agent, config, live_ship, config.extraction_waypoint)
    else
      {:error, reason} -> mark_autopilot_blocked(config, reason)
    end
  end

  defp sell_at_market(_agent, _config, _live_ship), do: {:error, :agent_token_missing}

  defp dock_for_market(_agent, %{nav: %{status: "DOCKED"}} = live_ship), do: {:ok, live_ship}

  defp dock_for_market(agent, live_ship) do
    with {:ok, result} <- SpaceTraders.API.dock_ship(agent.agent_token, live_ship.symbol) do
      {:ok, %{live_ship | nav: result.nav}}
    end
  end

  defp settle_market_cargo(agent, config, live_ship, market) do
    accepted = MapSet.new((market.imports || []) ++ (market.exchange || []), & &1.symbol)

    Enum.reduce_while(live_ship.cargo.inventory || [], {:ok, live_ship}, fn item, {:ok, ship} ->
      action_kind = if MapSet.member?(accepted, item.symbol), do: "sell", else: "jettison"

      case perform_market_cargo_action(agent, config, ship, item, action_kind) do
        {:ok, ship} -> {:cont, {:ok, ship}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp perform_market_cargo_action(agent, config, live_ship, item, kind) do
    action = %{
      "kind" => kind,
      "waypoint" => config.market_waypoint,
      "trade_symbol" => item.symbol,
      "expected" => %{"units_at_most" => item_units(live_ship, item.symbol) - item.units}
    }

    config =
      Repo.update!(
        Ecto.Changeset.change(config, status: "revalidating", in_flight_action: action)
      )

    request =
      if kind == "sell" do
        sell_cargo_for_autopilot(agent, live_ship.symbol, item.symbol, item.units)
      else
        jettison_cargo_for_autopilot(agent, live_ship.symbol, item.symbol, item.units)
      end

    case request do
      {:ok, %{cargo: cargo}} ->
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "ready",
            in_flight_action: nil,
            last_action_result: %{"kind" => kind, "trade_symbol" => item.symbol}
          )
        )

        {:ok, %{live_ship | cargo: cargo}}

      {:error, reason} ->
        mark_autopilot_blocked(config, {:market_cargo_action_failed, kind, item.symbol, reason})
    end
  end

  defp sell_cargo_for_autopilot(
         %AgentRecord{agent_token: token},
         ship_symbol,
         trade_symbol,
         units
       ) do
    SpaceTraders.API.sell_cargo(token, ship_symbol, trade_symbol, units)
  end

  defp jettison_cargo_for_autopilot(
         %AgentRecord{agent_token: token},
         ship_symbol,
         trade_symbol,
         units
       ) do
    SpaceTraders.API.jettison_cargo(token, ship_symbol, trade_symbol, units)
  end

  defp refuel_for_market_departure(agent, config, live_ship, market) do
    if fuel_full?(live_ship) do
      {:ok, live_ship}
    else
      with :ok <- fuel_available?(market),
           {:ok, live_ship} <- refuel_for_autopilot(agent, config, live_ship) do
        {:ok, live_ship}
      else
        {:error, reason} -> mark_autopilot_blocked(config, reason)
      end
    end
  end

  defp fuel_available?(market) do
    if Enum.any?(market.trade_goods || [], &(&1.symbol == "FUEL")) do
      :ok
    else
      {:error, {:market_fuel_unavailable, market.symbol}}
    end
  end

  defp fuel_full?(%{fuel: %{current: current, capacity: capacity}})
       when is_integer(current) and is_integer(capacity),
       do: current >= capacity

  defp fuel_full?(_), do: false

  defp refuel_for_autopilot(agent, config, live_ship) do
    action = %{
      "kind" => "refuel",
      "waypoint" => config.market_waypoint,
      "expected" => %{"fuel_full" => true}
    }

    config =
      Repo.update!(
        Ecto.Changeset.change(config, status: "revalidating", in_flight_action: action)
      )

    case SpaceTraders.API.refuel_ship(agent.agent_token, live_ship.symbol) do
      {:ok, %{fuel: fuel}} when fuel.current >= fuel.capacity ->
        Repo.update!(
          Ecto.Changeset.change(config,
            status: "ready",
            in_flight_action: nil,
            last_action_result: %{"kind" => "refuel", "fuel" => fuel.current}
          )
        )

        {:ok, %{live_ship | fuel: fuel}}

      {:ok, %{fuel: fuel}} ->
        mark_autopilot_blocked(
          config,
          {:market_fuel_insufficient, config.market_waypoint, fuel.current, fuel.capacity}
        )

      {:error, reason} ->
        mark_autopilot_blocked(config, {:market_refuel_failed, config.market_waypoint, reason})
    end
  end

  defp navigate_autopilot(agent, config, live_ship, waypoint) do
    if live_ship.nav.status == "DOCKED" do
      case SpaceTraders.API.orbit_ship(agent.agent_token, live_ship.symbol) do
        {:ok, result} ->
          navigate_autopilot(agent, config, %{live_ship | nav: result.nav}, waypoint)

        {:error, reason} ->
          mark_autopilot_blocked(config, reason)
      end
    else
      do_navigate_autopilot(agent, config, live_ship, waypoint)
    end
  end

  defp do_navigate_autopilot(agent, config, live_ship, waypoint) do
    action = %{
      "kind" => "navigate",
      "waypoint" => waypoint,
      "expected" => %{"status" => "IN_TRANSIT", "destination" => waypoint}
    }

    config =
      Repo.update!(
        Ecto.Changeset.change(config, status: "revalidating", in_flight_action: action)
      )

    case SpaceTraders.API.navigate_ship(agent.agent_token, live_ship.symbol, waypoint) do
      {:ok, result} ->
        maybe_schedule_arrival(agent, live_ship.symbol, result)

        {:ok,
         Repo.update!(
           Ecto.Changeset.change(config,
             status: "waiting",
             last_action_result: %{
               "kind" => "navigate",
               "waypoint" => waypoint,
               "status" => result.nav.status,
               "destination" => result.nav.route.destination.symbol
             },
             progress: Map.put(config.progress || %{}, "waypoint", waypoint)
           )
         )}

      {:error, reason} ->
        Repo.update!(
          Ecto.Changeset.change(config, status: "blocked", blocked_reason: inspect(reason))
        )

        {:error, reason}
    end
  end

  defp market_leg?(%AutopilotConfig{
         in_flight_action: %{"waypoint" => waypoint},
         market_waypoint: waypoint
       }),
       do: true

  defp market_leg?(%AutopilotConfig{
         progress: %{"waypoint" => waypoint},
         market_waypoint: waypoint
       }),
       do: true

  defp market_leg?(_), do: false

  defp pending_navigation?(%AutopilotConfig{
         status: "waiting",
         in_flight_action: %{"kind" => "navigate"}
       }),
       do: true

  defp pending_navigation?(_), do: false

  defp mark_autopilot_blocked(config, reason) do
    Repo.update!(
      Ecto.Changeset.change(config, status: "blocked", blocked_reason: inspect(reason))
    )

    {:error, reason}
  end

  defp extract_resources_for_autopilot(%AgentRecord{agent_token: token} = agent, ship_symbol)
       when is_binary(token) and token != "" do
    with {:ok, result} <- SpaceTraders.API.extract_resources(token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      {:ok, result}
    end
  end

  defp maybe_schedule_live_cooldown(agent, %{symbol: ship_symbol, cooldown: cooldown}) do
    due_at = parse_expiration(cooldown.expiration, cooldown.remaining_seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at)
  end

  defp cooldown_active?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds),
       do: seconds > 0

  defp cooldown_active?(_), do: false

  defp cargo_units(%{cargo: %{units: units}}) when is_integer(units), do: units
  defp cargo_units(_), do: 0

  defp item_units(%{cargo: %{inventory: inventory}}, symbol) do
    case Enum.find(inventory || [], &(&1.symbol == symbol)) do
      %{units: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  defp extraction_yield(%{extraction: %{yield: %{symbol: symbol, units: units}}}) do
    %{"symbol" => symbol, "units" => units}
  end

  defp extraction_yield(_), do: nil

  defp cooldown_ready?(%{cooldown: %{remaining_seconds: seconds}})
       when is_integer(seconds),
       do: seconds <= 0

  defp cooldown_ready?(_), do: true

  defp in_flight_arrival?(
         %AutopilotConfig{in_flight_action: %{"expected" => %{"destination" => destination}}},
         %{nav: %{status: "IN_TRANSIT", route: %{destination: %{symbol: destination}}}}
       ),
       do: true

  defp in_flight_arrival?(_, _), do: false

  @doc """
  Lists the waypoints of the Agent's headquarters system.

  The game paginates waypoint responses, so pages are fetched until the system
  is fully collected. Returns
  `{:ok, [%SpaceTraders.API.Model.Waypoint{}]}` or an API error.
  """
  def list_waypoints(%AgentRecord{agent_token: agent_token, headquarters: headquarters})
      when is_binary(agent_token) and agent_token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      fetch_waypoint_pages(agent_token, system)
    end
  end

  def list_waypoints(%AgentRecord{}), do: {:error, :agent_token_missing}

  defp fetch_waypoint_pages(agent_token, system) do
    Stream.iterate(1, &(&1 + 1))
    |> Enum.reduce_while({:ok, []}, fn page, {:ok, acc} ->
      case SpaceTraders.API.get_waypoints(agent_token, system, limit: 20, page: page) do
        {:ok, []} -> {:halt, {:ok, acc}}
        {:ok, waypoints} when length(waypoints) < 20 -> {:halt, {:ok, acc ++ waypoints}}
        {:ok, waypoints} -> {:cont, {:ok, acc ++ waypoints}}
        error -> {:halt, error}
      end
    end)
  end

  defp system_from_headquarters(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end

  @doc """
  Purchases a Ship offered by an on-site Shipyard in a Fleet command snapshot.

  The snapshot determines local purchase eligibility; the game remains the
  authoritative backstop if its listing changed after the snapshot was read.
  A successful purchase is returned even if its local restart-recovery record
  cannot be stored, with the persistence error in `:warning`.
  """
  def purchase_ship(%{agent: %AgentRecord{} = agent, shipyards: shipyards}, ship_type, waypoint) do
    with :ok <- offered_at?(shipyards, ship_type, waypoint),
         {:ok, result} <- Shipyard.purchase(agent, ship_type, waypoint) do
      {:ok, Map.put(result, :warning, record_purchase(agent, result.ship, ship_type))}
    end
  end

  @doc "Records a newly purchased ship so it can be re-armed after a restart."
  def record_ship(%AgentRecord{} = agent, ship_symbol, ship_type) do
    %Ship{}
    |> Ecto.Changeset.change(symbol: ship_symbol, ship_type: ship_type, agent_id: agent.id)
    |> Ecto.Changeset.validate_required([:symbol, :ship_type, :agent_id])
    |> Repo.insert(on_conflict: :nothing, conflict_target: :symbol)
  end

  @doc "Returns a Ship's five most recent successful navigation destinations."
  def destination_history(%AgentRecord{} = agent, ship_symbol) do
    ShipDestination
    |> join(:inner, [destination], ship in Ship, on: ship.id == destination.ship_id)
    |> where([destination, ship], ship.agent_id == ^agent.id and ship.symbol == ^ship_symbol)
    |> order_by([destination], asc: destination.position)
    |> limit(5)
    |> select([destination], destination.waypoint_symbol)
    |> Repo.all()
  end

  @doc """
  Navigates a ship to a waypoint.

  The ship is refused while a local arrival or cooldown is pending (the game
  API remains the backstop for anything the app hasn't seen). On success the
  returned nav shows `IN_TRANSIT` and the arrival is persisted to the timeline
  and armed on the ship's GenServer, so the card can show the arrival time and
  further actions stay blocked until the ship re-pulls its real state on
  arrival.

  Returns `{:ok, %{fuel: ..., nav: ...}}`, or one of:

    * `{:error, :ship_in_transit}` — the ship already has a pending arrival
    * `{:error, :cooldown_active}` — the ship has a pending cooldown
    * `{:error, :agent_token_missing}` — the agent has no stored AgentToken
    * `{:error, %SpaceTraders.API.Error{} | %SpaceTraders.API.GameplayError{}}` — API failure
  """
  def navigate_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol, waypoint_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <-
           SpaceTraders.API.navigate_ship(agent_token, ship_symbol, waypoint_symbol) do
      maybe_schedule_arrival(agent, ship_symbol, result)
      persist_destination_history(agent, ship_symbol, result.nav.route.destination.symbol)
      {:ok, result}
    end
  end

  def navigate_ship(%AgentRecord{}, _ship_symbol, _waypoint_symbol) do
    {:error, :agent_token_missing}
  end

  defp record_destination(agent, ship_symbol, waypoint_symbol) do
    with {:ok, ship} <- ensure_ship_record_for_history(agent, ship_symbol) do
      Repo.transaction(fn ->
        existing =
          Repo.get_by(ShipDestination, ship_id: ship.id, waypoint_symbol: waypoint_symbol)

        if existing do
          Repo.delete!(existing)

          Repo.update_all(
            from(destination in ShipDestination,
              where: destination.ship_id == ^ship.id and destination.position > ^existing.position
            ),
            inc: [position: -1]
          )
        end

        Repo.update_all(
          from(destination in ShipDestination, where: destination.ship_id == ^ship.id),
          inc: [position: 1]
        )

        Repo.insert!(%ShipDestination{
          ship_id: ship.id,
          waypoint_symbol: waypoint_symbol,
          position: 0
        })

        Repo.delete_all(
          from destination in ShipDestination,
            where: destination.ship_id == ^ship.id and destination.position > 4
        )
      end)
    end
  end

  defp ensure_ship_record_for_history(agent, ship_symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      %Ship{} = ship -> {:ok, ship}
      nil -> record_ship(agent, ship_symbol, "UNKNOWN")
    end
  end

  defp persist_destination_history(agent, ship_symbol, waypoint_symbol) do
    try do
      case record_destination(agent, ship_symbol, waypoint_symbol) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not persist destination history: #{inspect(reason)}")

        other ->
          Logger.warning("Could not persist destination history: #{inspect(other)}")
      end
    rescue
      exception ->
        Logger.warning("Could not persist destination history: #{Exception.message(exception)}")
    end
  end

  @doc "Docks a ship at its current waypoint."
  def dock_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.dock_ship(agent_token, ship_symbol)
    end
  end

  def dock_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Puts a ship into orbit at its current waypoint."
  def orbit_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.orbit_ship(agent_token, ship_symbol)
    end
  end

  def orbit_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Extracts resources and persists the returned cooldown on the timeline."
  def extract_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <- SpaceTraders.API.extract_resources(agent_token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      {:ok, result}
    end
  end

  def extract_resources(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Siphons gas and persists the returned cooldown on the timeline."
  def siphon_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, live_ship} <- SpaceTraders.API.get_ship(agent_token, ship_symbol),
         {:ok, waypoint} <-
           SpaceTraders.API.get_waypoint(
             agent_token,
             live_ship.nav.system_symbol,
             live_ship.nav.waypoint_symbol
           ),
         :ok <- siphon_location?(waypoint),
         :ok <- siphon_capability?(live_ship),
         {:ok, result} <- SpaceTraders.API.siphon_resources(agent_token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      {:ok, result}
    end
  end

  def siphon_resources(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  defp siphon_capability?(%{modules: modules, mounts: mounts}) do
    if Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_GAS_SIPHON_")) and
         Enum.any?(modules || [], &(&1.symbol == "MODULE_GAS_PROCESSOR_I")),
       do: :ok,
       else: {:error, :siphon_capability_missing}
  end

  defp siphon_capability?(_), do: {:error, :siphon_capability_missing}

  defp siphon_location?(%{type: "GAS_GIANT"}), do: :ok
  defp siphon_location?(_), do: {:error, :invalid_siphon_waypoint}

  @doc "Sells cargo from a ship and returns the updated cargo and transaction."
  def sell_cargo(%AgentRecord{agent_token: agent_token} = agent, ship_symbol, trade_symbol, units)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.sell_cargo(agent_token, ship_symbol, trade_symbol, units)
    end
  end

  def sell_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :agent_token_missing}

  @doc "Purchases cargo from a market the ship is docked at."
  def purchase_cargo(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(agent_token) and agent_token != "" and is_integer(units) and units > 0 do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.purchase_cargo(agent_token, ship_symbol, trade_symbol, units)
    end
  end

  def purchase_cargo(%AgentRecord{agent_token: token}, _ship_symbol, _trade_symbol, _units)
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def purchase_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :invalid_units}

  @doc "Refuels a ship at a marketplace that sells fuel."
  def refuel_ship(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.refuel_ship(agent_token, ship_symbol)
    end
  end

  def refuel_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Jettisons cargo from a ship's hold and returns the updated cargo."
  def jettison_cargo(
        %AgentRecord{agent_token: agent_token} = agent,
        ship_symbol,
        trade_symbol,
        units
      )
      when is_binary(agent_token) and agent_token != "" and is_integer(units) and units > 0 do
    with :ok <- preempt_autopilot_for(agent, ship_symbol, :manual_override),
         :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.jettison_cargo(agent_token, ship_symbol, trade_symbol, units)
    end
  end

  def jettison_cargo(%AgentRecord{agent_token: token}, _ship_symbol, _trade_symbol, _units)
      when not is_binary(token) or token == "",
      do: {:error, :agent_token_missing}

  def jettison_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :invalid_units}

  @doc """
  Re-arms ship servers for every ship with a pending timeline event.

  Called once on boot by `SpaceTraders.Fleet.ShipServerBoot`: each started
  server re-arms its own timers and immediately catches up events that came due
  while the app was down (ADR 0005). Ships without stored credentials are
  skipped with a warning. Returns `:ok`.
  """
  def rearm_ships_on_boot do
    timeline_symbols = Timeline.pending_owners(:ship) |> Enum.map(& &1.owner_id)

    autopilot_symbols =
      AutopilotConfig
      |> join(:inner, [c], s in Ship, on: c.ship_id == s.id)
      |> where([c, _s], c.desired_mode == "autopilot")
      |> select([_c, s], s.symbol)
      |> Repo.all()

    (timeline_symbols ++ autopilot_symbols)
    |> Enum.uniq()
    |> Enum.each(fn ship_symbol ->
      case ship_credentials(ship_symbol) do
        {:ok, agent_id, agent_token} ->
          ShipServer.ensure_started(ship_symbol, agent_id, agent_token)

          unless ship_symbol in timeline_symbols do
            recover_autopilot_on_boot(ship_symbol, agent_id, agent_token)
          end

        :error ->
          Logger.warning(
            "ship #{ship_symbol}: no stored credentials, not re-arming timeline events"
          )
      end
    end)

    :ok
  end

  @doc "Reconciles a persisted in-flight Autopilot action after a process restart."
  def recover_autopilot_on_boot(ship_symbol, agent_id, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %AutopilotConfig{} = config <- Repo.get_by(AutopilotConfig, ship_id: ship.id) do
      if config.desired_mode == "autopilot" do
        case SpaceTraders.API.get_ship(agent_token, ship_symbol) do
          {:ok, live_ship} when config.status == "ready" and is_nil(config.in_flight_action) ->
            advance_autopilot(Repo.get!(AgentRecord, agent_id), config, live_ship)

          {:ok, live_ship}
          when config.status in ["revalidating", "waiting"] and is_map(config.in_flight_action) ->
            reconcile_in_flight(agent_id, ship, config, live_ship)

          {:ok, _live_ship} ->
            :ok

          {:error, reason} ->
            recovery_retry_or_block(agent_id, ship_symbol, reason, agent_token)
        end
      else
        :ok
      end
    else
      _ -> :ok
    end
  end

  defp reconcile_in_flight(agent_id, ship, config, live_ship) do
    case action_outcome(config.in_flight_action, live_ship) do
      :confirmed ->
        recovered_config = confirm_recovery(config, live_ship)

        record_activity_by_id(
          agent_id,
          ship,
          "autopilot_recovery",
          "Autopilot action confirmed after restart",
          "confirmed"
        )

        if live_ship.nav.status == "IN_TRANSIT" do
          maybe_schedule_arrival(Repo.get!(AgentRecord, agent_id), live_ship.symbol, %{
            nav: live_ship.nav
          })

          {:ok, recovered_config}
        else
          advance_autopilot(
            Repo.get!(AgentRecord, agent_id),
            recovered_config,
            live_ship,
            :timeline
          )
        end

      :absent ->
        if config.recovery_attempts < 3 do
          retry_recovery(agent_id, ship, config, live_ship)
        else
          block_recovery(agent_id, ship, config, "retry_exhausted")
        end

      :ambiguous ->
        block_recovery(agent_id, ship, config, "ambiguous")
    end
  end

  defp action_outcome(%{"kind" => "navigate", "waypoint" => waypoint}, live_ship) do
    cond do
      live_ship.nav.status == "IN_TRANSIT" and live_ship.nav.route.destination.symbol == waypoint ->
        :confirmed

      at_extraction_waypoint?(live_ship, waypoint) or at_market_waypoint?(live_ship, waypoint) ->
        :confirmed

      true ->
        :absent
    end
  end

  defp action_outcome(
         %{"kind" => "extract", "expected" => %{"cargo_units_at_least" => units}},
         live_ship
       ) do
    if cargo_units(live_ship) >= units, do: :confirmed, else: :absent
  end

  defp action_outcome(
         %{"kind" => kind, "trade_symbol" => symbol, "expected" => %{"units_at_most" => units}},
         live_ship
       )
       when kind in ["sell", "jettison"] do
    if item_units(live_ship, symbol) <= units, do: :confirmed, else: :absent
  end

  defp action_outcome(%{"kind" => "refuel", "expected" => %{"fuel_full" => true}}, live_ship) do
    if fuel_full?(live_ship), do: :confirmed, else: :absent
  end

  defp action_outcome(_action, _live_ship), do: :ambiguous

  defp confirm_recovery(config, live_ship) do
    action = config.in_flight_action

    progress =
      if action["kind"] == "navigate" do
        Map.put(config.progress || %{}, "waypoint", action["waypoint"])
      else
        config.progress || %{}
      end

    Repo.update!(
      Ecto.Changeset.change(config,
        status: if(live_ship.nav.status == "IN_TRANSIT", do: "waiting", else: "ready"),
        blocked_reason: nil,
        recovery_attempts: 0,
        last_action_result: %{"kind" => "recovery", "outcome" => "confirmed"},
        progress: progress,
        in_flight_action:
          if(live_ship.nav.status == "IN_TRANSIT", do: config.in_flight_action, else: nil)
      )
    )
  end

  defp retry_recovery(agent_id, ship, config, live_ship) do
    attempts = config.recovery_attempts + 1

    config = Repo.update!(Ecto.Changeset.change(config, recovery_attempts: attempts))

    record_activity_by_id(
      agent_id,
      ship,
      "autopilot_recovery",
      "Autopilot action absent; retrying",
      "absent"
    )

    case advance_autopilot(Repo.get!(AgentRecord, agent_id), config, live_ship, :timeline) do
      {:ok, recovered_config} ->
        {:ok, Repo.update!(Ecto.Changeset.change(recovered_config, recovery_attempts: 0))}

      error ->
        error
    end
  end

  defp recovery_retry_or_block(agent_id, ship_symbol, reason, agent_token) do
    with %Ship{} = ship <- Repo.get_by(Ship, symbol: ship_symbol, agent_id: agent_id),
         %AutopilotConfig{desired_mode: "autopilot"} = config <-
           Repo.get_by(AutopilotConfig, ship_id: ship.id) do
      if config.recovery_attempts < 3 do
        Repo.update!(
          Ecto.Changeset.change(config, recovery_attempts: config.recovery_attempts + 1)
        )

        record_activity_by_id(
          agent_id,
          ship,
          "autopilot_recovery",
          "Authoritative recovery read failed; retrying",
          "transport_error"
        )

        recover_autopilot_on_boot(ship_symbol, agent_id, agent_token)
      else
        block_recovery(agent_id, ship, config, "retry_exhausted: #{inspect(reason)}")
      end
    else
      _ -> :ok
    end
  end

  defp block_recovery(agent_id, ship, config, outcome) do
    Repo.update!(
      Ecto.Changeset.change(config,
        status: "blocked",
        blocked_reason: "Autopilot recovery #{outcome}; no game action was replayed",
        last_action_result: %{"kind" => "recovery", "outcome" => outcome}
      )
    )

    record_activity_by_id(
      agent_id,
      ship,
      "autopilot_recovery",
      "Autopilot recovery blocked: #{outcome}",
      outcome
    )

    {:error, :autopilot_recovery_blocked}
  end

  defp record_activity_by_id(agent_id, ship, kind, message, outcome) do
    record_activity(Repo.get!(AgentRecord, agent_id), ship, kind, message, %{"outcome" => outcome})
  end

  defp maybe_schedule_arrival(agent, ship_symbol, %{nav: %ShipNav{status: "IN_TRANSIT"} = nav}) do
    with {:ok, due_at} <- parse_arrival(nav.route) do
      {:ok, event} =
        Timeline.schedule_event(:ship, ship_symbol, :arrival, due_at, arrival_payload(nav))

      ShipServer.arm(agent, ship_symbol, event)
    end
  end

  defp maybe_schedule_arrival(_agent, _ship_symbol, _result), do: :ok

  defp schedule_cooldown(agent, ship_symbol, %{
         cooldown: %{remaining_seconds: seconds, expiration: expiration}
       })
       when is_integer(seconds) and seconds > 0 do
    due_at = parse_expiration(expiration, seconds)
    schedule_cooldown_event(agent, ship_symbol, due_at)
  end

  defp schedule_cooldown(_agent, _ship_symbol, _result), do: :ok

  defp parse_expiration(expiration, seconds) when is_binary(expiration) do
    case DateTime.from_iso8601(expiration) do
      {:ok, due_at, _offset} -> due_at
      _ -> DateTime.add(DateTime.utc_now(), seconds, :second)
    end
  end

  defp parse_expiration(_expiration, seconds),
    do: DateTime.add(DateTime.utc_now(), seconds, :second)

  defp schedule_cooldown_event(agent, ship_symbol, due_at) do
    {:ok, event} = Timeline.schedule_event(:ship, ship_symbol, :cooldown, due_at)
    ShipServer.arm(agent, ship_symbol, event)
  end

  defp parse_arrival(%ShipNavRoute{arrival: arrival}) when is_binary(arrival) do
    case DateTime.from_iso8601(arrival) do
      {:ok, due_at, _offset} ->
        {:ok, due_at}

      _ ->
        Logger.warning("ship arrival #{arrival} is not a parseable timestamp")
        :error
    end
  end

  defp parse_arrival(_route), do: :error

  defp arrival_payload(%ShipNav{route: %{destination: %{symbol: destination}}})
       when is_binary(destination),
       do: %{destination: destination}

  defp arrival_payload(_nav), do: %{}

  defp snapshot_listings(agent, {:ok, ships}, waypoints),
    do: Listing.for_ships(agent, ships, waypoints)

  defp snapshot_listings(_agent, _ships, _waypoints),
    do: %{shipyards: {:ok, []}, markets: {:ok, []}}

  defp annotate_listing_actions(%{markets: markets, shipyards: shipyards}, overview) do
    %{
      markets: annotate_market_actions(markets),
      shipyards: annotate_purchase_actions(shipyards, overview)
    }
  end

  defp annotate_market_actions({status, listings}) when status in [:ok, :partial] do
    {status,
     Enum.map(listings, fn %{market: market, ships: ships} = listing ->
       ships = Enum.map(ships, &Map.put(&1, :trade_actions, trade_actions(&1, market)))
       %{listing | ships: ships}
     end)}
  end

  defp annotate_market_actions(result), do: result

  defp trade_actions(ship, %{trade_goods: goods}) do
    Map.new(goods || [], fn good ->
      {good.symbol,
       %{
         sell: action_state(item_units(ship, good.symbol) > 0, :cargo_missing),
         buy: purchase_cargo_state(ship, good)
       }}
    end)
  end

  defp trade_actions(_ship, _market), do: %{}

  defp purchase_cargo_state(ship, good) do
    available_space = cargo_capacity(ship) - cargo_units(ship)
    available? = (good.purchase_price || 0) > 0 and available_space > 0
    reason = if (good.purchase_price || 0) > 0, do: :cargo_full, else: :trade_unavailable
    action_state(available?, reason)
  end

  defp cargo_capacity(%{cargo: %{capacity: capacity}}) when is_integer(capacity), do: capacity
  defp cargo_capacity(_), do: 0

  defp annotate_purchase_actions({status, listings}, overview) when status in [:ok, :partial] do
    {status,
     Enum.map(listings, fn %{shipyard: %{ships: ships}} = listing ->
       actions =
         Map.new(ships || [], fn ship ->
           {ship.type, purchase_ship_state(overview, ship.purchase_price)}
         end)

       Map.put(listing, :purchase_actions, actions)
     end)}
  end

  defp annotate_purchase_actions(result, _overview), do: result

  defp purchase_ship_state({:ok, %{credits: credits}}, price)
       when is_integer(credits) and is_integer(price),
       do: action_state(credits >= price, :insufficient_credits)

  defp purchase_ship_state(_overview, _price), do: action_state(true, nil)

  defp offered_at?({status, listings}, ship_type, waypoint) when status in [:ok, :partial] do
    if Enum.any?(listings, &offered_in_listing?(&1, ship_type, waypoint)) do
      :ok
    else
      {:error, :shipyard_unavailable}
    end
  end

  defp offered_at?(_, _ship_type, _waypoint), do: {:error, :shipyard_unavailable}

  defp offered_in_listing?(%{waypoint: waypoint, shipyard: %{ships: ships}}, ship_type, waypoint) do
    Enum.any?(ships || [], &(&1.type == ship_type))
  end

  defp offered_in_listing?(_, _ship_type, _waypoint), do: false

  defp record_purchase(agent, ship, ship_type) do
    case record_ship(agent, ship.symbol, ship_type) do
      {:ok, _ship} -> nil
      {:error, reason} -> {:ship_record_failed, reason}
    end
  end

  defp ship_credentials(ship_symbol) do
    query =
      from(s in Ship,
        join: a in assoc(s, :agent),
        where: s.symbol == ^ship_symbol,
        select: {a.id, a.agent_token}
      )

    case Repo.one(query) do
      {agent_id, agent_token} when is_binary(agent_token) and agent_token != "" ->
        {:ok, agent_id, agent_token}

      _ ->
        :error
    end
  end
end
