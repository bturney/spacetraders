defmodule SpaceTraders.Fleet do
  @moduledoc """
  The Fleet context: the ships an Agent owns and their live state.

  A ship's live state — location, fuel, cargo, cooldown, nav status — is pulled
  from the game through `SpaceTraders.API`. The server is the source of truth;
  the local `ships` table is the app's registry of owned ships (seeded with the
  starter fleet) and carries no live state. The Fleet read interfaces expose
  live game state independently of the retired per-Ship gameplay dashboard.

  Ship actions here orchestrate the game call and the app's async model: after a
  successful navigate the pending arrival is persisted to the timeline and armed
  on the ship's GenServer, so the ship stays busy until it actually arrives
  (ADR 0005).
  """

  import Ecto.Query, warn: false
  require Logger

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.Fleet.{Activity, IntentBlocker, Ship, ShipCargo, ShipDestination}

  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Intelligence, World}

  @doc """
  Pulls the agent's live fleet from the game API.

  Each ship carries its current nav (location + docked/orbiting/transit state),
  fuel, cargo and cooldown — the data the fleet cards render.

  Returns `{:ok, [%SpaceTraders.API.Model.Ship{}]}` or an API error. An agent
  without a stored AgentToken returns `{:error, :agent_token_missing}`.
  """
  def list_ships(%AgentRecord{agent_token: agent_token} = agent)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- Agent.execution_allowed?(agent) do
      Agent.handle_game_result(agent, SpaceTraders.Evidence.get_ships(token_reference(agent)))
    end
  end

  def list_ships(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc "Subscribes the caller to `{:ship_state, %Ship{}}`, one message per stored Ship change."
  def subscribe_ship_state(agent_id) when is_integer(agent_id),
    do: Phoenix.PubSub.subscribe(SpaceTraders.PubSub, ship_state_topic(agent_id))

  defp ship_state_topic(agent_id), do: "ship_state:#{agent_id}"

  @doc """
  Subscribes the caller to Intent status changes of every Ship, as
  `{:intent_changed, ship_id}`: a prompt to re-read, never data. It may arrive
  before the change commits, so readers re-read after a short delay.
  """
  def subscribe_intent_changes,
    do: Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "intent_changes")

  @doc false
  def broadcast_intent_change(ship_id),
    do:
      Phoenix.PubSub.broadcast(SpaceTraders.PubSub, "intent_changes", {:intent_changed, ship_id})

  @doc """
  Current Ships of an Agent with their stored state and Cargo, in natural name
  order (`AGENT-2` before `AGENT-10`). Reads only the database.
  """
  def current_ships(agent_id) when is_integer(agent_id) do
    from(ship in Ship,
      where: ship.agent_id == ^agent_id and is_nil(ship.retired_at),
      preload: [:cargo]
    )
    |> Repo.all()
    |> Enum.sort_by(&name_order(&1.symbol))
  end

  @doc "The given current Ships of an Agent, as `current_ships/1` reads them."
  def current_ships(agent_id, ship_ids) when is_integer(agent_id) and is_list(ship_ids) do
    from(ship in Ship,
      where: ship.agent_id == ^agent_id and is_nil(ship.retired_at) and ship.id in ^ship_ids,
      preload: [:cargo]
    )
    |> Repo.all()
    |> Enum.sort_by(&name_order(&1.symbol))
  end

  # The game numbers an Agent's Ships with a hexadecimal suffix (`-9`, `-A`,
  # `-10`): order by prefix, then by that number.
  defp name_order(symbol) do
    {prefix, suffix} =
      case symbol |> String.split("-") |> Enum.split(-1) do
        {[], [only]} -> {"", only}
        {parts, [last]} -> {Enum.join(parts, "-"), last}
      end

    case Integer.parse(suffix, 16) do
      {n, ""} -> {prefix, 0, n, suffix}
      _ -> {prefix, 1, 0, suffix}
    end
  end

  @doc """
  Stores what one Ship-bearing game response says about the Agent's Ships.

  Called by `SpaceTraders.API` with every decoded success: whole Ships (owned
  Fleet and Ship reads, purchases, registration) and the partial nav, fuel and
  Cargo a Ship action returns for the Ship named in its path.
  """
  def record_ship_response(agent_id, path, response) when is_integer(agent_id) do
    response
    |> ship_facts(path)
    |> Enum.each(fn {symbol, facts} -> record_ship_state(agent_id, symbol, facts) end)
  rescue
    exception ->
      Logger.error("Ship state not recorded: #{Exception.message(exception)}")
      :ok
  end

  def record_ship_response(_agent_id, _path, _response), do: :ok

  defp ship_facts(ships, _path) when is_list(ships),
    do: Enum.flat_map(ships, &ship_facts(&1, nil))

  defp ship_facts(%SpaceTraders.API.Model.Ship{symbol: symbol} = ship, _path)
       when is_binary(symbol),
       do: [{symbol, Map.from_struct(ship)}]

  defp ship_facts(%{ship: %SpaceTraders.API.Model.Ship{} = ship}, _path),
    do: ship_facts(ship, nil)

  defp ship_facts(%{ships: ships}, _path) when is_list(ships), do: ship_facts(ships, nil)

  defp ship_facts(%{} = response, path) when is_binary(path) and not is_struct(response) do
    with ["my", "ships", symbol, _action | _] <- String.split(path, "/", trim: true),
         facts when map_size(facts) > 0 <- Map.take(response, [:nav, :fuel, :cargo, :cooldown]) do
      [{symbol, facts}]
    else
      _ -> []
    end
  end

  defp ship_facts(_response, _path), do: []

  @doc """
  The one upsert of a registered Ship's current state from game facts (any of
  `:nav`, `:fuel`, `:cargo`, `:cooldown`, `:engine`, `:frame`). Absent facts keep their last
  observed value; Cargo is replaced as a set. Unregistered Ships are ignored:
  registration stays with authoritative acquisition. Broadcasts the stored Ship.
  """
  def record_ship_state(agent_id, symbol, facts) when is_binary(symbol) and is_map(facts) do
    changes =
      facts
      |> state_changes()
      |> Map.put(:state_observed_at, SpaceTraders.Clock.utc_now())

    {:ok, ship} =
      Repo.transaction(fn ->
        from(ship in Ship,
          where:
            ship.agent_id == ^agent_id and ship.symbol == ^symbol and is_nil(ship.retired_at),
          lock: "FOR UPDATE"
        )
        |> Repo.one()
        |> case do
          nil ->
            nil

          ship ->
            ship = ship |> Ecto.Changeset.change(changes) |> Repo.update!()
            replace_cargo(ship, Map.get(facts, :cargo))
            Repo.preload(ship, :cargo, force: true)
        end
      end)

    if ship do
      Phoenix.PubSub.broadcast(
        SpaceTraders.PubSub,
        ship_state_topic(agent_id),
        {:ship_state, ship}
      )
    end

    {:ok, ship}
  end

  defp state_changes(facts) do
    [
      engine_changes(Map.get(facts, :engine)),
      frame_changes(Map.get(facts, :frame)),
      fuel_changes(Map.get(facts, :fuel)),
      cargo_capacity_changes(Map.get(facts, :cargo)),
      nav_changes(Map.get(facts, :nav)),
      cooldown_changes(Map.get(facts, :cooldown))
    ]
    |> Enum.reduce(%{}, &Map.merge(&2, &1))
  end

  defp engine_changes(%{speed: speed, condition: condition}),
    do: %{engine_speed: speed, engine_condition: condition && condition / 1}

  defp engine_changes(_), do: %{}

  defp frame_changes(%{fuel_capacity: capacity}) when is_integer(capacity),
    do: %{fuel_capacity: capacity}

  defp frame_changes(_), do: %{}

  defp fuel_changes(%{current: current, capacity: capacity}),
    do: Map.reject(%{fuel_current: current, fuel_capacity: capacity}, &is_nil(elem(&1, 1)))

  defp fuel_changes(_), do: %{}

  defp cargo_capacity_changes(%{capacity: capacity}) when is_integer(capacity),
    do: %{cargo_capacity: capacity}

  defp cargo_capacity_changes(_), do: %{}

  defp nav_changes(%{status: status} = nav) when is_binary(status) do
    route = nav.route || %{}

    %{
      nav_status: status,
      waypoint_symbol: nav.waypoint_symbol,
      route_origin: route_waypoint(Map.get(route, :origin)),
      route_destination: route_waypoint(Map.get(route, :destination)),
      route_departed_at: route_time(Map.get(route, :departure_time)),
      route_arrives_at: route_time(Map.get(route, :arrival))
    }
  end

  defp nav_changes(_), do: %{}

  defp cooldown_changes(%{remaining_seconds: seconds, expiration: expiration})
       when is_integer(seconds) and seconds > 0,
       do: %{cooldown_expires_at: route_time(expiration)}

  defp cooldown_changes(%{remaining_seconds: seconds}) when is_integer(seconds),
    do: %{cooldown_expires_at: nil}

  defp cooldown_changes(_), do: %{}

  defp route_waypoint(%{symbol: symbol}), do: symbol
  defp route_waypoint(_), do: nil

  defp route_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> DateTime.truncate(time, :second)
      _ -> nil
    end
  end

  defp route_time(_), do: nil

  defp replace_cargo(_ship, nil), do: :ok

  defp replace_cargo(ship, cargo) do
    Repo.delete_all(from item in ShipCargo, where: item.ship_id == ^ship.id)

    rows =
      for %{symbol: symbol, units: units} <- cargo.inventory || [],
          is_binary(symbol) and is_integer(units) and units > 0 do
        %{ship_id: ship.id, trade_symbol: symbol, units: units}
      end

    Repo.insert_all(ShipCargo, rows)
    :ok
  end

  @doc """
  Registers a Ship in the local registry after authoritative evidence.

  The `ships` table is the app's registry of owned Ships and carries no live
  state, so a Ship may only be registered once an authoritative read has
  established the capabilities its acquisition promised. Registration grants no
  Claim; Fleet Allocation does that separately.
  """
  def register_ship(%AgentRecord{} = agent, %{symbol: symbol} = observed, ship_type)
      when is_binary(symbol) and symbol != "" and is_binary(ship_type) and ship_type != "" do
    now = DateTime.utc_now(:second)

    result =
      case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
        nil ->
          Repo.insert(%Ship{agent_id: agent.id, symbol: symbol, ship_type: ship_type})

        ship ->
          Repo.update(Ecto.Changeset.change(ship, ship_type: ship_type, updated_at: now))
      end

    case result do
      {:ok, ship} ->
        # The authoritative read arrived before the row existed.
        record_ship_response(agent.id, nil, observed)
        {:ok, ship}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def register_ship(_agent, _ship, _ship_type), do: {:error, :invalid_ship_registration}

  @doc """
  Reads everything the Fleet command panel displays for an Agent.

  Each live read remains independent: an unavailable Agent overview or Shipyard
  does not hide the rest of the Agent's Fleet. The game remains the source of
  truth, so every call assembles fresh data.
  """
  def command_snapshot(%AgentRecord{} = agent) do
    if Agent.stale?(agent) or SpaceTraders.FleetGeneration.gameplay_authority(agent.id) != :ok do
      stale_snapshot(agent)
    else
      overview = Agent.agent_overview(agent)

      if overview == {:error, :stale_agent} do
        stale_snapshot(agent)
      else
        ships = list_ships(agent) |> annotate_ships(agent)

        ships = annotate_actions(ships) |> annotate_control_state()
        waypoints = retained_waypoints(agent)
        activity = recent_activity(agent) |> annotate_activity()

        listings =
          snapshot_listings(agent, ships, waypoints) |> annotate_listing_actions(overview)

        %{
          agent: agent,
          stale?: false,
          overview: overview,
          ships: ships,
          contracts: Contracts.list_contracts(agent),
          shipyards: listings.shipyards,
          markets: listings.markets,
          waypoints: waypoints,
          activity: activity,
          control: fleet_control(ships)
        }
      end
    end
  end

  defp stale_snapshot(agent) do
    %{
      agent: agent,
      stale?: true,
      overview: {:error, :stale_agent},
      ships: {:error, :stale_agent},
      contracts: {:error, :stale_agent},
      shipyards: {:error, :stale_agent},
      markets: {:error, :stale_agent},
      waypoints: {:error, :stale_agent},
      activity: [],
      control: %{healthy?: false}
    }
  end

  # These facts keep operational interpretation at the Ship Execution boundary.
  # The dashboard can still render the underlying game state without recreating
  # operational decisions.
  defp annotate_control_state({:ok, ships}) do
    {:ok,
     Enum.map(ships, fn ship ->
       Map.put(ship, :control, %{
         readiness: %{flight_mode: ship_flight_mode(ship)},
         navigation: %{
           available?: Map.get(Map.get(ship, :actions, %{}), :navigate, %{})[:allowed?] == true,
           selectable?: ship_status(ship) == "IN_ORBIT",
           destinations: Map.get(ship, :destination_history, [])
         }
       })
     end)}
  end

  defp annotate_control_state(result), do: result

  defp fleet_control({:ok, ships}) do
    %{
      healthy?:
        ships != [] and not Enum.any?(ships, &match?(%{intents: %{status: "blocked"}}, &1))
    }
  end

  defp fleet_control(_), do: %{healthy?: false}

  defp ship_flight_mode(%{nav: %{flight_mode: mode}}) when is_binary(mode), do: mode
  defp ship_flight_mode(_), do: "—"

  defp annotate_activity(activity) do
    Enum.map(activity, fn event ->
      Map.put(event, :control, %{
        visible?: not activity_noise?(event),
        facts: activity_facts(event)
      })
    end)
  end

  defp activity_noise?(%{kind: kind}) when kind in ["retry", "manual_intent_waiting"], do: true

  defp activity_noise?(%{kind: kind, message: message})
       when kind in ["owned_intent_recovery"] do
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

  @doc "Reads Market data for a selected Waypoint when it is a Marketplace."
  def waypoint_market(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with :ok <- market_waypoint?(waypoint),
         %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.Evidence.get_market(token_reference(agent), system, symbol, bind: true) do
        {:ok, %SpaceTraders.Evidence.Binding{value: market, observation: source}} ->
          record_market_observation(agent, system, market, "get_market", nil, evidence: source)
          {:ok, market}

        {:error, %SpaceTraders.API.GameplayError{}} = result ->
          invalidate_market_facts(agent, system, symbol)
          result

        result ->
          result
      end
    else
      {:error, :invalid_market_waypoint} -> :not_a_marketplace
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_market(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Reads and records authoritative Construction facts for a selected Waypoint."
  def waypoint_construction(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.Evidence.get_construction(token_reference(agent), system, symbol) do
        {:ok, construction} = result ->
          record_construction_observation(agent, system, construction, "get_construction")
          result

        {:error, %SpaceTraders.API.GameplayError{}} = result ->
          Intelligence.mark_unavailable(agent, :construction, system, symbol, [:complete],
            source: "get_construction"
          )

          result

        result ->
          result
      end
    else
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_construction(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Reads and records a Jump Gate's connections without inferring Construction readiness."
  def waypoint_jump_gate(%AgentRecord{agent_token: token} = agent, waypoint)
      when is_binary(token) and token != "" do
    with %{system_symbol: system, symbol: symbol} when is_binary(system) and is_binary(symbol) <-
           waypoint do
      case SpaceTraders.Evidence.get_jump_gate(token_reference(agent), system, symbol) do
        {:ok, gate} = result ->
          record_jump_gate_observation(agent, system, gate, "get_jump_gate")
          result

        {:error, %SpaceTraders.API.GameplayError{}} = result ->
          Intelligence.mark_unavailable(agent, :jump_gate, system, symbol, [:connections],
            source: "get_jump_gate"
          )

          result

        result ->
          result
      end
    else
      _ -> {:error, :waypoint_unavailable}
    end
  end

  def waypoint_jump_gate(%AgentRecord{}, _waypoint), do: {:error, :agent_token_missing}

  @doc "Returns recent local events for an Agent, newest first."
  def recent_activity(%AgentRecord{} = agent) do
    Activity
    |> where([a], a.agent_id == ^agent.id)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> preload(:ship)
    |> Repo.all()
  end

  defp annotate_ships({:ok, ships}, agent) do
    ship_records = Enum.map(ships, &ensure_ship_record(agent, &1))
    intents_by_ship = intents_for_ships(agent)
    intent_history_by_ship = intents_history_for_ships(agent)

    {:ok,
     Enum.map(ships, fn ship ->
       ship_record = Enum.find(ship_records, &(&1.symbol == ship.symbol))

       ship
       |> Map.put(:intents, Map.get(intents_by_ship, ship_record.id))
       |> Map.put(:intents_history, Map.get(intent_history_by_ship, ship_record.id, []))
       |> Map.put(:destination_history, destination_history(agent, ship.symbol))
     end)}
  end

  defp annotate_ships(result, _agent), do: result

  defp intents_for_ships(agent) do
    agent
    |> SpaceTraders.Fleet.Intents.current()
    |> Enum.filter(&(&1.caller == "commitment"))
    |> Map.new(&{&1.ship_id, &1})
  end

  defp intents_history_for_ships(agent) do
    agent
    |> SpaceTraders.Fleet.Intents.history()
    |> Enum.filter(&(&1.caller == "commitment"))
    |> Enum.group_by(& &1.ship_id)
  end

  defp annotate_actions({:ok, ships}) do
    {:ok, Enum.map(ships, &Map.put(&1, :actions, ship_actions(&1)))}
  end

  defp annotate_actions(result), do: result

  # Outcome-level Navigate is always dispatchable: its Intent reconciles
  # authoritative location, transit, posture, fuel, arrival, and cooldown
  # instead of refusing while the Ship is busy.
  defp ship_actions(ship) do
    cooldown = cooldown_active?(ship)
    status = ship_status(ship)

    %{
      navigate: action_state(true, nil),
      set_flight_mode:
        action_state(
          status != "IN_TRANSIT",
          :ship_in_transit
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
    case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
      %Ship{} = ship ->
        ship

      nil ->
        case record_ship(agent, symbol, "UNKNOWN") do
          {:ok, %Ship{id: id} = ship} when is_integer(id) ->
            ship

          {:ok, _conflict} ->
            Repo.get_by!(Ship, agent_id: agent.id, symbol: symbol)

          {:error, changeset} ->
            raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
        end
    end
  end

  @doc "Returns a Ship's locally registered ownership record for an Agent."
  def owned_ship(agent, symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: symbol) do
      nil -> {:error, :ship_not_owned}
      ship -> {:ok, ship}
    end
  end

  @doc false
  def record_activity(agent, ship, kind, message, metadata \\ %{}) do
    message = SpaceTraders.Observability.redact(message, agent.agent_token)
    metadata = SpaceTraders.Observability.redact(metadata, agent.agent_token)

    Repo.insert!(%Activity{
      agent_id: agent.id,
      ship_id: ship.id,
      kind: kind,
      message: message,
      metadata: metadata
    })

    SpaceTraders.Observability.fleet_activity(agent, ship, kind, metadata)
    :ok
  end

  def record_destination(agent, ship_symbol, waypoint_symbol) do
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

  def destination_history(%AgentRecord{} = agent, ship_symbol) do
    ShipDestination
    |> join(:inner, [destination], ship in Ship, on: ship.id == destination.ship_id)
    |> where([destination, ship], ship.agent_id == ^agent.id and ship.symbol == ^ship_symbol)
    |> order_by([destination], asc: destination.position)
    |> limit(5)
    |> select([destination], destination.waypoint_symbol)
    |> Repo.all()
  end

  @doc false
  def market_for_ship(%AgentRecord{} = agent, live_ship, waypoint_symbol) do
    system_symbol = live_ship.nav.system_symbol

    case Agent.handle_game_result(
           agent,
           SpaceTraders.Evidence.get_market(
             token_reference(agent),
             system_symbol,
             waypoint_symbol,
             required_facts: ["trade_goods", "transactions"],
             freshness_seconds: 60,
             bind: true
           )
         ) do
      {:ok, %SpaceTraders.Evidence.Binding{value: market, observation: source}} ->
        observer = if live_ship.nav.waypoint_symbol == waypoint_symbol, do: live_ship.symbol

        record_market_observation(agent, system_symbol, market, "get_market", observer,
          evidence: source
        )

        {:ok, market}

      {:error, %SpaceTraders.API.GameplayError{}} = result ->
        invalidate_market_facts(agent, system_symbol, waypoint_symbol)
        result

      result ->
        result
    end
  end

  @doc false
  def list_waypoints(%AgentRecord{agent_token: agent_token, headquarters: headquarters} = agent)
      when is_binary(agent_token) and agent_token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      case fetch_waypoint_pages(token_reference(agent), system) do
        {:ok, waypoints} = result ->
          Enum.each(waypoints, &record_waypoint_observation(agent, &1, "get_waypoints"))

          if is_integer(agent.operator_id) do
            Phoenix.PubSub.broadcast(
              SpaceTraders.PubSub,
              "fleet_intelligence_evidence",
              {:waypoint_intelligence_observed, agent.id, system}
            )
          end

          result

        result ->
          result
      end
    end
  end

  def list_waypoints(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc false
  def record_construction_observation(%AgentRecord{id: id} = agent, system, construction, source)
      when is_integer(id) do
    Intelligence.observe_construction(agent, system, construction, source: source)
  rescue
    exception ->
      Logger.warning(
        "Could not persist construction intelligence: #{Exception.message(exception)}"
      )
  end

  def record_construction_observation(_agent, _system, _construction, _source), do: :ok

  @doc false
  def cooldown_active?(%{cooldown: %{remaining_seconds: seconds}})
      when is_integer(seconds),
      do: seconds > 0

  def cooldown_active?(_), do: false

  @doc false
  def item_units(%{cargo: %{inventory: inventory}}, symbol),
    do: inventory_units(inventory, symbol)

  def item_units(%{inventory: inventory}, symbol), do: inventory_units(inventory, symbol)

  @doc false
  def system_from_headquarters(headquarters) when is_binary(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end

  def system_from_headquarters(_headquarters), do: {:error, :invalid_headquarters}

  @doc false
  def record_ship(%AgentRecord{} = agent, ship_symbol, ship_type) do
    %Ship{}
    |> Ecto.Changeset.change(symbol: ship_symbol, ship_type: ship_type, agent_id: agent.id)
    |> Ecto.Changeset.validate_required([:symbol, :ship_type, :agent_id])
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: {:unsafe_fragment, "(symbol) WHERE retired_at IS NULL"}
    )
  end

  defp market_waypoint?(%{traits: traits}) do
    if Enum.any?(traits || [], &(&1.symbol == "MARKETPLACE")),
      do: :ok,
      else: {:error, :invalid_market_waypoint}
  end

  defp market_waypoint?(_), do: {:error, :invalid_market_waypoint}

  defp siphon_capability?(%{modules: modules, mounts: mounts}) do
    if Enum.any?(mounts || [], &String.starts_with?(&1.symbol || "", "MOUNT_GAS_SIPHON_")) and
         Enum.any?(modules || [], &(&1.symbol == "MODULE_GAS_PROCESSOR_I")),
       do: :ok,
       else: {:error, :siphon_capability_missing}
  end

  defp siphon_capability?(_), do: {:error, :siphon_capability_missing}

  defp record_jump_gate_observation(%AgentRecord{id: id} = agent, system, gate, source)
       when is_integer(id) do
    Intelligence.observe_jump_gate(agent, system, gate, source: source)
  rescue
    exception ->
      Logger.warning("Could not persist jump-gate intelligence: #{Exception.message(exception)}")
  end

  defp record_jump_gate_observation(_agent, _system, _gate, _source), do: :ok

  @doc "Retains or invalidates Construction facts from a recorded Ship action result."
  def record_construction_result(
        {:ok, %{construction: construction}} = result,
        agent,
        system_symbol,
        _waypoint_symbol,
        ship_symbol
      ) do
    Intelligence.observe_construction(agent, system_symbol, construction,
      source: "supply_construction",
      observing_ship_symbol: ship_symbol
    )

    result
  rescue
    exception ->
      Logger.warning(
        "Could not persist supplied construction intelligence: #{Exception.message(exception)}"
      )

      result
  end

  def record_construction_result(
        {:error, %SpaceTraders.API.GameplayError{}} = result,
        agent,
        system_symbol,
        waypoint_symbol,
        _ship_symbol
      ) do
    Intelligence.invalidate(agent, :construction, system_symbol, waypoint_symbol)
    result
  rescue
    exception ->
      Logger.warning(
        "Could not invalidate construction intelligence: #{Exception.message(exception)}"
      )

      result
  end

  def record_construction_result(result, _agent, _system, _waypoint, _ship), do: result

  def recipient_fulfilled_units(%{terms: terms}, trade_symbol) do
    case Enum.find(terms.deliver || [], &(&1.trade_symbol == trade_symbol)) do
      %{units_fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  def recipient_fulfilled_units(%{materials: materials}, trade_symbol) do
    case Enum.find(materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: units} when is_integer(units) -> units
      _ -> 0
    end
  end

  def transaction_evidence(transaction) do
    %{
      "type" => transaction.type,
      "trade_symbol" => transaction.trade_symbol,
      "ship_symbol" => transaction.ship_symbol,
      "waypoint_symbol" => transaction.waypoint_symbol,
      "units" => transaction.units,
      "price_per_unit" => transaction.price_per_unit,
      "total_price" => transaction.total_price
    }
  end

  def find_deliverable(%{terms: %{deliver: deliver}}, trade_symbol) do
    Enum.find(deliver || [], &(&1.trade_symbol == trade_symbol))
  end

  def find_deliverable(_contract, _trade_symbol), do: nil

  def contract_delivery_evidence(contract, trade_symbol) do
    case find_deliverable(contract, trade_symbol) do
      nil -> %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
      delivery -> %{"trade_symbol" => trade_symbol, "units_fulfilled" => delivery.units_fulfilled}
    end
  end

  def construction_delivery_evidence(construction, trade_symbol) do
    case Enum.find(construction.materials || [], &(&1.trade_symbol == trade_symbol)) do
      %{fulfilled: fulfilled} when is_integer(fulfilled) ->
        %{"trade_symbol" => trade_symbol, "units_fulfilled" => fulfilled}

      _ ->
        %{"trade_symbol" => trade_symbol, "accepted" => "unavailable"}
    end
  end

  defp ensure_ship_record_for_history(agent, ship_symbol) do
    case Repo.get_by(Ship, agent_id: agent.id, symbol: ship_symbol) do
      %Ship{} = ship -> {:ok, ship}
      nil -> record_ship(agent, ship_symbol, "UNKNOWN")
    end
  end

  defp record_market_observation(
         %AgentRecord{id: id} = agent,
         system,
         market,
         source,
         observer,
         lineage
       )
       when is_integer(id) do
    Intelligence.observe_market(
      agent,
      system,
      market,
      [source: source, observing_ship_symbol: observer] ++ lineage
    )
  rescue
    exception ->
      Logger.warning("Could not persist market intelligence: #{Exception.message(exception)}")
  end

  defp record_market_observation(_agent, _system, _market, _source, _observer, _lineage),
    do: :ok

  defp invalidate_market_facts(agent, system_symbol, waypoint_symbol) do
    Intelligence.invalidate(agent, :market, system_symbol, waypoint_symbol, [
      :trade_goods,
      :transactions
    ])
  rescue
    exception ->
      Logger.warning("Could not invalidate market intelligence: #{Exception.message(exception)}")
  end

  defp fetch_waypoint_pages(credential_ref, system) do
    case SpaceTraders.Evidence.get_waypoints_paginated(credential_ref, system, [],
           discovery: true
         ) do
      {:ok, waypoints} -> {:ok, waypoints}
      {:error, reason, _collected} -> {:error, reason}
    end
  end

  defp record_waypoint_observation(%AgentRecord{id: id} = agent, waypoint, source)
       when is_integer(id) do
    Intelligence.observe_waypoint(agent, waypoint, source: source)
  rescue
    exception ->
      Logger.warning("Could not persist waypoint intelligence: #{Exception.message(exception)}")
  end

  defp record_waypoint_observation(_agent, _waypoint, _source), do: :ok

  defp inventory_units(inventory, symbol) do
    case Enum.find(inventory || [], fn item ->
           (Map.get(item, :symbol) || Map.get(item, "symbol")) == symbol
         end) do
      item when is_map(item) -> Map.get(item, :units) || Map.get(item, "units") || 0
      _ -> 0
    end
  end

  defp cargo_units(%{cargo: %{units: units}}) when is_integer(units), do: units
  defp cargo_units(_), do: 0

  defp token_reference(%AgentRecord{} = agent), do: AgentTokenReference.new(agent)

  @doc false
  def record_activity_by_id(agent_id, ship, kind, message, outcome) do
    record_activity(Repo.get!(AgentRecord, agent_id), ship, kind, message, %{"outcome" => outcome})
  end

  @doc false
  def intent_blocker(reason) do
    {resolver, retry_condition, corrective_actions} = blocker_resolution(reason)

    %IntentBlocker{
      reason: blocker_reason(reason),
      summary: blocker_summary(reason),
      evidence: inspect(reason),
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      resolver: resolver,
      retry_condition: retry_condition,
      corrective_actions: corrective_actions
    }
  end

  defp blocker_summary("ambiguous"),
    do: "The game did not confirm whether the in-flight action completed."

  defp blocker_summary(:api_capacity_deferred),
    do: "The game asked the Fleet to wait; the action was rejected before it applied."

  defp blocker_summary("retry_exhausted" <> _),
    do: "Authoritative recovery could not complete within its retry budget."

  defp blocker_summary({:jump_gate_incomplete, waypoint}),
    do: "Jump Gate #{waypoint} is not complete."

  defp blocker_summary({:jump_gate_not_connected, source, destination}),
    do: "Jump Gate #{source} is not connected to #{destination}."

  defp blocker_summary({:jump_route_candidates, reason, _candidates}),
    do: "Jump route blocked: #{blocker_reason(reason)}."

  defp blocker_summary(:ambiguous_jump_evidence),
    do: "The jump response is ambiguous; authoritative Ship state did not confirm arrival."

  defp blocker_summary(:target_system_waypoints_unavailable),
    do: "System exploration cannot progress: target system waypoints are unavailable."

  defp blocker_summary(reason)
       when reason in [
              :insufficient_unreserved_headroom,
              :authoritative_credit_facts_required,
              :credit_spending_paused,
              :credit_calibration_superseded
            ],
       do:
         "Spending stays paused: credits cannot cover this fuel or antimatter purchase above the credit floor."

  defp blocker_summary(reason), do: "Ship action cannot progress: #{blocker_reason(reason)}."

  defp blocker_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp blocker_reason({:jump_route_candidates, reason, _candidates}), do: blocker_reason(reason)
  defp blocker_reason(reason) when is_tuple(reason), do: reason |> elem(0) |> blocker_reason()
  defp blocker_reason(%{__struct__: module}), do: module |> Module.split() |> List.last()

  defp blocker_reason("retry_exhausted:" <> _evidence), do: "retry_exhausted"
  defp blocker_reason(reason) when is_binary(reason), do: reason
  defp blocker_reason(_reason), do: "action_blocked"

  defp blocker_resolution(reason) do
    case {blocker_reason(reason), reason} do
      {"api_capacity_deferred", _reason} ->
        {"game_state", "api_capacity_available", ["resume"]}

      {code, _reason}
      when code in [
             "invalid_extraction_waypoint",
             "invalid_siphon_waypoint",
             "invalid_market_waypoint",
             "cargo_threshold_exceeds_capacity"
           ] ->
        {"operator", "configuration_changed", ["replace_intent", "resume"]}

      {code, _reason} when code in ["siphon_capability_missing", "mining_capability_missing"] ->
        {"operator", "ship_capability_changed", ["outfit_ship", "resume"]}

      {"agent_token_missing", _reason} ->
        {"operator", "agent_credentials_restored", ["restore_credentials", "resume"]}

      {"insufficient_fuel", _reason} ->
        {"operator", "ship_refueled", ["refuel"]}

      {"fuel_unavailable", _reason} ->
        {"game_state", "fuel_observation_available", ["refresh_ship", "refuel"]}

      {code, _reason}
      when code in [
             "insufficient_unreserved_headroom",
             "authoritative_credit_facts_required",
             "credit_spending_paused",
             "credit_calibration_superseded"
           ] ->
        {"operator", "credits_above_floor_with_headroom", ["acquire_credits", "resume"]}

      {code, _reason}
      when code in ["market_quote_stale_or_missing", "market_quote_unavailable"] ->
        {"game_state", "fresh_market_quote_available", ["refresh_market", "resume"]}

      {code, _reason}
      when code in ["modification_fee_stale_or_missing", "modification_fee_unavailable"] ->
        {"game_state", "fresh_shipyard_fee_available", ["refresh_shipyard", "resume"]}

      {code, _reason} when code in ["insufficient_credits", "antimatter_unavailable"] ->
        {"operator", "jump_resources_available", ["acquire_credits", "buy_antimatter", "resume"]}

      {code, _reason}
      when code in [
             "construction_unavailable",
             "construction_intelligence_unavailable",
             "destination_construction_incomplete"
           ] ->
        {"operator", "construction_intelligence_and_completion_available",
         ["inspect_construction", "supply_construction", "resume"]}

      {"jump_gate_intelligence_unavailable", _reason} ->
        {"operator", "jump_gate_intelligence_available", ["inspect_jump_gate", "resume"]}

      {code, _reason}
      when code in ["navigation_budget_unavailable", "reverse_connection_unavailable"] ->
        {"operator", "navigable_route_available",
         ["inspect_waypoint", "choose_connected_gate", "resume"]}

      {"orbit_required", _reason} ->
        {"operator", "ship_in_orbit", ["orbit", "resume"]}

      {"cooldown_active", _reason} ->
        {"game_state", "cooldown_elapsed", ["wait_for_cooldown", "resume"]}

      {"jump_gate_incomplete", _reason} ->
        {"operator", "construction_completed",
         ["inspect_construction", "supply_construction", "resume"]}

      {"jump_gate_not_connected", _reason} ->
        {"operator", "connected_gate_selected",
         ["inspect_jump_gate", "choose_connected_gate", "resume"]}

      {"ambiguous_jump_evidence", _reason} ->
        {"game_state", "authoritative_arrival_confirmed", ["inspect_activity", "reconcile"]}

      {"outside_system", _reason} ->
        {"operator", "cross_system_navigate_available", []}

      {"unreadable_arrival", _reason} ->
        {"game_state", "authoritative_state_changed", ["resume"]}

      {"ambiguous", _reason} ->
        {"game_state", "authoritative_action_outcome_available",
         ["inspect_activity", "reconcile_and_retry"]}

      {"retry_exhausted", _reason} ->
        {"game_state", "authoritative_read_succeeds", ["reconcile"]}

      {_code, reason} when is_struct(reason) ->
        {"game_state", "authoritative_read_succeeds", ["resume"]}

      {_code, _reason} ->
        {"game_state", "authoritative_state_changed", ["resume"]}
    end
  end

  defp retained_waypoints(%AgentRecord{headquarters: headquarters} = agent)
       when is_binary(headquarters) do
    case system_from_headquarters(headquarters) do
      {:ok, system} ->
        waypoints =
          agent
          |> World.waypoints(system, DateTime.utc_now(), 300)
          |> Enum.map(fn waypoint ->
            %{
              symbol: waypoint.symbol,
              system_symbol: system,
              type: fact_value(waypoint.facts["type"]),
              x: fact_value(waypoint.facts["x"]),
              y: fact_value(waypoint.facts["y"]),
              traits: fact_value(waypoint.facts["traits"]),
              modifiers: fact_value(waypoint.facts["modifiers"])
            }
          end)

        {:ok, waypoints}

      _ ->
        {:error, :invalid_headquarters}
    end
  end

  defp retained_waypoints(%AgentRecord{}), do: {:error, :invalid_headquarters}

  defp fact_value(%{state: "known", value: value}), do: value
  defp fact_value(_fact), do: nil

  defp snapshot_listings(_agent, {:ok, _ships}, {:ok, _waypoints}),
    do: %{shipyards: {:ok, []}, markets: {:ok, []}}

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

  @doc false
  def ship_agent(ship_symbol) do
    query =
      from(s in Ship,
        join: a in assoc(s, :agent),
        where: s.symbol == ^ship_symbol and is_nil(s.retired_at),
        select: a
      )

    case Repo.one(query) do
      %AgentRecord{agent_token: agent_token} = agent
      when is_binary(agent_token) and agent_token != "" ->
        {:ok, agent}

      _ ->
        :error
    end
  end
end
