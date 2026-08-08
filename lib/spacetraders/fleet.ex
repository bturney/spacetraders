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

  @doc "Records a newly purchased ship so it can be re-armed after a restart."
  def record_ship(%AgentRecord{} = agent, ship_symbol, ship_type) do
    %Ship{}
    |> Ecto.Changeset.change(symbol: ship_symbol, ship_type: ship_type, agent_id: agent.id)
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
