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

  def agent_scopes(keys) do
    Enum.flat_map(keys, fn key ->
      case String.split(key, ":") do
        [type, agent_id | _]
        when type in ~w(ship agent_credits owned_fleet contract construction waypoint) ->
          [agent(agent_id)]

        _ ->
          []
      end
    end)
  end

  def observation_subject("get-my-ship", [key], _agent_symbol) do
    case String.split(key, ":", parts: 3) do
      ["ship", _, symbol] -> "ship:#{symbol}"
      _ -> nil
    end
  end

  def observation_subject("get-my-agent", _keys, symbol), do: "agent:#{symbol}"
  def observation_subject("get-my-ships", _keys, symbol), do: "fleet:#{symbol}"
  def observation_subject("get-contracts", _keys, symbol), do: "contracts:#{symbol}"

  def observation_subject("get-construction", [key], _symbol) do
    with ["construction", _, waypoint] <- String.split(key, ":", parts: 3),
         {:ok, system} <- SpaceTraders.Fleet.system_from_headquarters(waypoint) do
      "construction:#{system}:#{waypoint}"
    else
      _ -> nil
    end
  end

  def observation_subject("get-waypoint", [key], _symbol) do
    with ["waypoint", _, waypoint] <- String.split(key, ":", parts: 3),
         {:ok, system} <- SpaceTraders.Fleet.system_from_headquarters(waypoint) do
      "waypoint:#{system}:#{waypoint}"
    else
      _ -> nil
    end
  end

  def observation_subject(_, _, _), do: nil

  defp encode(type, parts) do
    Enum.map_join([type | parts], ":", &to_string/1)
  end
end
