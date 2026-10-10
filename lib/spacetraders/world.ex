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
      |> Map.put(
        :construction,
        intelligence(agent, :construction, system, symbol, as_of, freshness_seconds)
      )
    end)
  end

  # A FUEL Listing older than this is not a confirmed fuel stop.
  @fuel_listing_freshness_seconds 300

  @doc """
  Known Waypoint coordinates in `system`. Coordinates are static game facts,
  so any retained observation of them counts, however old.
  """
  def waypoint_coordinates(%AgentRecord{} = agent, system) when is_binary(system) do
    for symbol <- Intelligence.known_waypoints(agent, system),
        facts = Intelligence.subject(agent, :waypoint, system, symbol),
        %{state: "known", value: x} when is_integer(x) <- [facts["x"]],
        %{state: "known", value: y} when is_integer(y) <- [facts["y"]],
        into: %{},
        do: {symbol, %{x: x, y: y}}
  end

  @doc """
  The confirmed fuel stops in `system` at `as_of`: Waypoints with known
  coordinates whose Market Listing, fresh at `as_of`, sells FUEL. Fleet
  Planning and Ship Execution both judge fuel reach from this one answer.
  """
  def fuel_stops(%AgentRecord{} = agent, system, %DateTime{} = as_of) when is_binary(system) do
    coordinates = waypoint_coordinates(agent, system)

    for symbol <- coordinates |> Map.keys() |> Enum.sort(),
        market =
          intelligence(agent, :market, system, symbol, as_of, @fuel_listing_freshness_seconds),
        %{freshness: :fresh, value: goods} when is_list(goods) <- [market.facts["trade_goods"]],
        Enum.any?(goods, &(Map.get(&1, "symbol") == "FUEL")),
        do: symbol
  end

  def intelligence(%AgentRecord{} = agent, type, system, symbol, as_of, freshness_seconds)
      when type in [:waypoint, :market, :shipyard, :construction] and is_binary(system) and
             is_binary(symbol) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    facts = Intelligence.subject(agent, type, system, symbol)

    %{
      subject: {type, system, symbol},
      known_existence?: known_existence?(type, facts),
      facts:
        Map.new(facts, fn {field, fact} -> {field, project(fact, as_of, freshness_seconds)} end)
    }
  end

  defp known_existence?(:construction, facts) do
    Enum.any?(facts, fn {_field, fact} -> fact.state == "known" end)
  end

  defp known_existence?(_type, facts) do
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
