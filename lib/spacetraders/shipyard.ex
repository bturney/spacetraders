defmodule SpaceTraders.Shipyard do
  @moduledoc "Shipyard discovery, listings and ship purchases for an Agent."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Listing

  @shipyard_trait "SHIPYARD"

  @doc "Finds shipyard waypoints in the Agent's headquarters system."
  def discover(%AgentRecord{agent_token: token, headquarters: headquarters})
      when is_binary(token) and token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      SpaceTraders.API.get_waypoints(token, system, traits: @shipyard_trait)
    end
  end

  def discover(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc "Returns shipyard data for shipyards where at least one supplied ship is docked."
  def listings(%AgentRecord{agent_token: token}, ships)
      when is_binary(token) and token != "" and is_list(ships) do
    ships_by_system =
      Listing.docked_by_system(ships)

    {waypoints, unavailable?} =
      Listing.discover_waypoints(token, Map.keys(ships_by_system), @shipyard_trait)

    on_site =
      waypoints
      |> Enum.filter(fn waypoint ->
        Enum.any?(
          Map.get(ships_by_system, waypoint.system_symbol, []),
          &at?(&1, waypoint.symbol)
        )
      end)
      |> Enum.uniq_by(& &1.symbol)
      |> Enum.sort_by(& &1.symbol)

    {listings, unavailable?} =
      Enum.reduce(on_site, {[], unavailable?}, fn waypoint, {listings, unavailable?} ->
        case shipyard(token, waypoint.system_symbol, waypoint.symbol) do
          {:ok, shipyard} ->
            {[%{waypoint: waypoint.symbol, shipyard: shipyard} | listings], unavailable?}

          {:error, _reason} ->
            {listings, true}
        end
      end)

    Listing.result(Enum.reverse(listings), unavailable?)
  end

  def listings(%AgentRecord{}, _ships), do: {:error, :agent_token_missing}

  @doc "Reads a shipyard's listings at a waypoint."
  def shipyard(%AgentRecord{agent_token: token}, _waypoint)
      when not is_binary(token) or token == "" do
    {:error, :agent_token_missing}
  end

  def shipyard(%AgentRecord{agent_token: token, headquarters: headquarters}, waypoint) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      SpaceTraders.API.get_shipyard(token, system, waypoint)
    end
  end

  @doc "Purchases a ship at a shipyard waypoint."
  def purchase(%AgentRecord{agent_token: token}, _ship_type, _waypoint)
      when not is_binary(token) or token == "" do
    {:error, :agent_token_missing}
  end

  def purchase(%AgentRecord{agent_token: token}, ship_type, waypoint) do
    with {:ok, %{transaction: transaction, ship: ship}} <-
           SpaceTraders.API.purchase_ship(token, ship_type, waypoint) do
      {:ok, %{transaction: transaction, ship: ship}}
    end
  end

  defp shipyard(token, system, waypoint) do
    SpaceTraders.API.get_shipyard(token, system, waypoint)
  end

  defp at?(%{nav: %{waypoint_symbol: waypoint}}, waypoint), do: true
  defp at?(_, _), do: false

  defp system_from_headquarters(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end
end
