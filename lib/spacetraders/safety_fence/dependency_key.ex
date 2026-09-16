defmodule SpaceTraders.SafetyFence.DependencyKey do
  @moduledoc false

  def agent(agent_id), do: encode(:agent, [agent_id])
  def agent_credits(agent_id), do: encode(:agent_credits, [agent_id])
  def agent_symbol(operator_id, symbol), do: encode(:agent_symbol, [operator_id, symbol])
  def construction(agent_id, waypoint), do: encode(:construction, [agent_id, waypoint])
  def contract(agent_id, contract_id), do: encode(:contract, [agent_id, contract_id])
  def owned_fleet(agent_id), do: encode(:owned_fleet, [agent_id])
  def operator(operator_id), do: encode(:operator, [operator_id])
  def ship(agent_id, ship_symbol), do: encode(:ship, [agent_id, ship_symbol])
  def waypoint(agent_id, waypoint_symbol), do: encode(:waypoint, [agent_id, waypoint_symbol])

  defp encode(type, parts) do
    Enum.map_join([type | parts], ":", &to_string/1)
  end
end
