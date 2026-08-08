defmodule SpaceTraders.Market do
  @moduledoc "Market discovery and prices for an Agent's on-site ships."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model.Ship

  @market_trait "MARKETPLACE"

  @doc "Returns market data only for marketplace waypoints with a ship on-site."
  def listings(%AgentRecord{agent_token: token}, ships)
      when is_binary(token) and token != "" and is_list(ships) do
    ships_by_system =
      ships
      |> Enum.filter(&on_site?/1)
      |> Enum.group_by(& &1.nav.system_symbol)

    with {:ok, waypoints} <- discover(token, Map.keys(ships_by_system)) do
      waypoints
      |> Enum.map(fn waypoint ->
        on_site =
          Enum.filter(
            Map.get(ships_by_system, waypoint.system_symbol, []),
            &at?(&1, waypoint.symbol)
          )

        {waypoint, on_site}
      end)
      |> Enum.reject(fn {_waypoint, ships} -> ships == [] end)
      |> Enum.reduce_while({:ok, []}, fn {waypoint, ships}, {:ok, listings} ->
        case SpaceTraders.API.get_market(token, waypoint.system_symbol, waypoint.symbol) do
          {:ok, market} ->
            {:cont,
             {:ok, [%{waypoint: waypoint.symbol, market: market, ships: ships} | listings]}}

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

  def listings(%AgentRecord{}, _ships), do: {:error, :agent_token_missing}

  defp discover(_token, []), do: {:ok, []}

  defp discover(token, systems) do
    Enum.reduce_while(systems, {:ok, []}, fn system, {:ok, waypoints} ->
      case SpaceTraders.API.get_waypoints(token, system, traits: @market_trait) do
        {:ok, found} ->
          found = Enum.filter(found, &marketplace?/1)
          {:cont, {:ok, waypoints ++ found}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp on_site?(%Ship{nav: %{status: status, system_symbol: system}})
       when status != "IN_TRANSIT" and is_binary(system),
       do: true

  defp on_site?(_), do: false

  defp at?(%{nav: %{waypoint_symbol: waypoint}}, waypoint), do: true
  defp at?(_, _), do: false

  defp marketplace?(%{traits: traits}) when is_list(traits) do
    Enum.any?(traits, &(&1.symbol == @market_trait))
  end

  defp marketplace?(_), do: false
end
