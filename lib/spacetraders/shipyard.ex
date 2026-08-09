defmodule SpaceTraders.Shipyard do
  @moduledoc "Shipyard discovery, listings and ship purchases for an Agent."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model.Ship

  @shipyard_trait "SHIPYARD"

  @doc "Finds shipyard waypoints in the Agent's headquarters system."
  def discover(%AgentRecord{agent_token: token, headquarters: headquarters})
      when is_binary(token) and token != "" and is_binary(headquarters) do
    with {:ok, system} <- system_from_headquarters(headquarters) do
      SpaceTraders.API.get_waypoints(token, system, traits: @shipyard_trait)
    end
  end

  def discover(%AgentRecord{}), do: {:error, :agent_token_missing}

  @doc "Returns shipyard data for shipyards where at least one supplied ship is on-site."
  def listings(%AgentRecord{} = agent, ships) when is_list(ships) do
    with {:ok, waypoints} <- discover(agent) do
      on_site =
        waypoints
        |> Enum.filter(fn waypoint -> Enum.any?(ships, &on_site?(&1, waypoint.symbol)) end)
        |> Enum.uniq_by(& &1.symbol)

      Enum.reduce_while(on_site, {:ok, []}, fn waypoint, {:ok, listings} ->
        case shipyard(agent, waypoint.symbol) do
          {:ok, shipyard} ->
            {:cont, {:ok, [%{waypoint: waypoint.symbol, shipyard: shipyard} | listings]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> case do
        {:ok, listings} -> {:ok, Enum.reverse(listings)}
        error -> error
      end
    end
  end

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

  defp on_site?(%Ship{nav: %{status: status, waypoint_symbol: symbol}}, symbol)
       when status != "IN_TRANSIT",
       do: true

  defp on_site?(%{nav: %{status: status, waypoint_symbol: symbol}}, symbol)
       when status != "IN_TRANSIT",
       do: true

  defp on_site?(_, _), do: false

  defp system_from_headquarters(headquarters) do
    case Regex.run(~r/^(.+)-[^-]+$/, headquarters, capture: :all) do
      [_, system] -> {:ok, system}
      _ -> {:error, :invalid_headquarters}
    end
  end
end
