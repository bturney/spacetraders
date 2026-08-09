defmodule SpaceTraders.Market do
  @moduledoc "Market discovery and prices for an Agent's on-site ships."

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Listing

  @doc "Returns market data only for marketplace waypoints with a ship on-site."
  def listings(%AgentRecord{} = agent, ships) when is_list(ships) do
    Listing.for_ships(agent, ships, {:error, :waypoints_unavailable}).markets
  end

  def listings(%AgentRecord{}, _ships), do: {:error, :agent_token_missing}
end
