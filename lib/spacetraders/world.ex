defmodule SpaceTraders.World do
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence

  def waypoints(%AgentRecord{} = agent, system, as_of, freshness_seconds)
      when is_binary(system) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    agent
    |> Intelligence.known_waypoints(system)
    |> Enum.map(fn symbol ->
      waypoint = intelligence(agent, :waypoint, system, symbol, as_of, freshness_seconds)

      waypoint
      |> Map.put(:symbol, symbol)
      |> Map.put(:market, intelligence(agent, :market, system, symbol, as_of, freshness_seconds))
      |> Map.put(
        :shipyard,
        intelligence(agent, :shipyard, system, symbol, as_of, freshness_seconds)
      )
    end)
  end

  def intelligence(%AgentRecord{} = agent, type, system, symbol, as_of, freshness_seconds)
      when type in [:waypoint, :market, :shipyard] and is_binary(system) and
             is_binary(symbol) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    facts = Intelligence.subject(agent, type, system, symbol)

    %{
      subject: {type, system, symbol},
      known_existence?: known_existence?(facts),
      facts:
        Map.new(facts, fn {field, fact} -> {field, project(fact, as_of, freshness_seconds)} end)
    }
  end

  defp known_existence?(facts) do
    case facts["symbol"] do
      %{state: "known", value: symbol} when is_binary(symbol) and symbol != "" -> true
      _ -> false
    end
  end

  defp project(fact, as_of, freshness_seconds) do
    observation = fact.observation
    age = DateTime.diff(as_of, observation.observed_at, :second)

    %{
      state: fact.state,
      value: if(fact.state == "known", do: fact.value),
      freshness:
        cond do
          fact.state != "known" -> :not_established
          age >= 0 and age <= freshness_seconds -> :fresh
          true -> :stale
        end,
      observed_at: observation.observed_at,
      observation_id: observation.id,
      source: source_label(observation.source),
      observing_ship_symbol: observation.observing_ship_symbol
    }
  end

  defp source_label("get_waypoint"), do: "Public Waypoint observation"
  defp source_label("get_waypoints"), do: "Public Waypoint observation"
  defp source_label("get_market"), do: "Market observation"
  defp source_label("get_shipyard"), do: "Shipyard observation"
  defp source_label("scan_waypoints"), do: "Ship scan"
  defp source_label("create_chart"), do: "Chart"
  defp source_label(_), do: "Game observation"
end
