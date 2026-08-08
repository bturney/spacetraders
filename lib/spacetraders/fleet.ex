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
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.ShipServer
  alias SpaceTraders.Repo
  alias SpaceTraders.{Agent, Contracts, Market, Shipyard}
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
    ships = list_ships(agent)

    %{
      agent: agent,
      overview: Agent.agent_overview(agent),
      ships: ships,
      contracts: Contracts.list_contracts(agent),
      shipyards: shipyard_listings(agent, ships),
      markets: market_listings(agent, ships),
      waypoints: list_waypoints(agent)
    }
  end

  @doc """
  Lists the waypoints of the Agent's headquarters system.

  The game paginates waypoint responses, so pages are fetched until the system
  is fully collected (capped at `@max_waypoint_pages`). Returns
  `{:ok, [%SpaceTraders.API.Model.Waypoint{}]}` or an API error.
  """
  def list_waypoints(%AgentRecord{agent_token: agent_token, headquarters: headquarters})
      when is_binary(agent_token) and agent_token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      fetch_waypoint_pages(agent_token, system)
    end
  end

  def list_waypoints(%AgentRecord{}), do: {:error, :agent_token_missing}

  @max_waypoint_pages 5

  defp fetch_waypoint_pages(agent_token, system) do
    Enum.reduce_while(1..@max_waypoint_pages, {:ok, []}, fn page, {:ok, acc} ->
      case SpaceTraders.API.get_waypoints(agent_token, system, limit: 20, page: page) do
        {:ok, []} -> {:halt, {:ok, acc}}
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
    with :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <-
           SpaceTraders.API.navigate_ship(agent_token, ship_symbol, waypoint_symbol) do
      maybe_schedule_arrival(agent, ship_symbol, result)
      {:ok, result}
    end
  end

  def navigate_ship(%AgentRecord{}, _ship_symbol, _waypoint_symbol) do
    {:error, :agent_token_missing}
  end

  @doc "Docks a ship at its current waypoint."
  def dock_ship(%AgentRecord{agent_token: agent_token}, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.dock_ship(agent_token, ship_symbol)
    end
  end

  def dock_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Puts a ship into orbit at its current waypoint."
  def orbit_ship(%AgentRecord{agent_token: agent_token}, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.orbit_ship(agent_token, ship_symbol)
    end
  end

  def orbit_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Extracts resources and persists the returned cooldown on the timeline."
  def extract_resources(%AgentRecord{agent_token: agent_token} = agent, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- ShipServer.ensure_ready(ship_symbol),
         {:ok, result} <- SpaceTraders.API.extract_resources(agent_token, ship_symbol),
         :ok <- schedule_cooldown(agent, ship_symbol, result) do
      {:ok, result}
    end
  end

  def extract_resources(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Sells cargo from a ship and returns the updated cargo and transaction."
  def sell_cargo(%AgentRecord{agent_token: agent_token}, ship_symbol, trade_symbol, units)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.sell_cargo(agent_token, ship_symbol, trade_symbol, units)
    end
  end

  def sell_cargo(%AgentRecord{}, _ship_symbol, _trade_symbol, _units),
    do: {:error, :agent_token_missing}

  @doc "Refuels a ship at a marketplace that sells fuel."
  def refuel_ship(%AgentRecord{agent_token: agent_token}, ship_symbol)
      when is_binary(agent_token) and agent_token != "" do
    with :ok <- ShipServer.ensure_ready(ship_symbol) do
      SpaceTraders.API.refuel_ship(agent_token, ship_symbol)
    end
  end

  def refuel_ship(%AgentRecord{}, _ship_symbol), do: {:error, :agent_token_missing}

  @doc "Jettisons cargo from a ship's hold and returns the updated cargo."
  def jettison_cargo(%AgentRecord{agent_token: agent_token}, ship_symbol, trade_symbol, units)
      when is_binary(agent_token) and agent_token != "" and is_integer(units) and units > 0 do
    with :ok <- ShipServer.ensure_ready(ship_symbol) do
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
    Timeline.pending_owners(:ship)
    |> Enum.each(fn %{owner_id: ship_symbol} ->
      case ship_credentials(ship_symbol) do
        {:ok, agent_id, agent_token} ->
          ShipServer.ensure_started(ship_symbol, agent_id, agent_token)

        :error ->
          Logger.warning(
            "ship #{ship_symbol}: no stored credentials, not re-arming timeline events"
          )
      end
    end)

    :ok
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

  defp shipyard_listings(agent, {:ok, ships}), do: Shipyard.listings(agent, ships)
  defp shipyard_listings(_agent, _ships), do: {:ok, []}

  defp market_listings(agent, {:ok, ships}), do: Market.listings(agent, ships)
  defp market_listings(_agent, _ships), do: {:ok, []}

  defp offered_at?({:ok, listings}, ship_type, waypoint) do
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
