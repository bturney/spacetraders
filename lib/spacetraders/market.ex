defmodule SpaceTraders.Market do
  @moduledoc "Market discovery and prices for an Agent's on-site ships."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Listing

  @market_trait "MARKETPLACE"

  @doc "Returns market data only for marketplace waypoints with a docked ship."
  def listings(%AgentRecord{agent_token: token}, ships)
      when is_binary(token) and token != "" and is_list(ships) do
    ships_by_system =
      Listing.docked_by_system(ships)

    {waypoints, unavailable?} =
      Listing.discover_waypoints(token, Map.keys(ships_by_system), @market_trait)

    {listings, unavailable?} =
      waypoints
      |> Enum.sort_by(& &1.symbol)
      |> Enum.map(fn waypoint ->
        on_site =
          Enum.filter(
            Map.get(ships_by_system, waypoint.system_symbol, []),
            &at?(&1, waypoint.symbol)
          )

        {waypoint, on_site}
      end)
      |> Enum.reject(fn {_waypoint, ships} -> ships == [] end)
      |> Enum.reduce({[], unavailable?}, fn {waypoint, ships}, {listings, unavailable?} ->
        case SpaceTraders.API.get_market(token, waypoint.system_symbol, waypoint.symbol) do
          {:ok, market} ->
            {[%{waypoint: waypoint.symbol, market: market, ships: ships} | listings],
             unavailable?}

          {:error, _reason} ->
            {listings, true}
        end
      end)

    Listing.result(Enum.reverse(listings), unavailable?)
  end

  def listings(%AgentRecord{}, _ships), do: {:error, :agent_token_missing}

  defp at?(%{nav: %{waypoint_symbol: waypoint}}, waypoint), do: true
  defp at?(_, _), do: false
end
