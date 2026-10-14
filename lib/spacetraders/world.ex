defmodule SpaceTraders.World do
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence

  @subject_types [:waypoint, :market, :shipyard, :construction]

  # A FUEL Listing older than this is not a confirmed fuel stop.
  @fuel_listing_freshness_seconds Intelligence.market_freshness_seconds()

  @doc """
  One retained read of `system` for an explicit Agent: the same
  `:waypoints`, `:waypoint_coordinates` and `:fuel_stops` that `waypoints/4`,
  `waypoint_coordinates/2` and `fuel_stops/3` return at `as_of`.

  At most two SELECTs however many Waypoints or retained observations (one
  for an empty System). Nothing is cached: each call reads again, so a later
  call reflects any intervening observation, invalidation or Agent change.
  """
  def projections(%AgentRecord{} = agent, system, as_of, freshness_seconds)
      when is_binary(system) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    symbols = Intelligence.known_waypoints(agent, system)
    subjects = Intelligence.subjects(agent, system, @subject_types, symbols)
    facts = fn type, symbol -> Map.fetch!(subjects, {type, symbol}) end

    waypoints =
      Enum.map(symbols, &waypoint(&1, system, as_of, freshness_seconds, facts))

    coordinates = coordinates(symbols, &facts.(:waypoint, &1))

    fuel_stops =
      Enum.filter(waypoints, fn %{symbol: symbol, market: market} ->
        Map.has_key?(coordinates, symbol) and sells_fresh_fuel?(market)
      end)
      |> Enum.map(& &1.symbol)

    %{waypoints: waypoints, waypoint_coordinates: coordinates, fuel_stops: fuel_stops}
  end

  # `freshness_seconds` judges Waypoint, Shipyard and Construction facts; the
  # Market Listing always uses the Market freshness budget.
  def waypoints(%AgentRecord{} = agent, system, as_of, freshness_seconds)
      when is_binary(system) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    facts = fn type, symbol -> Intelligence.subject(agent, type, system, symbol) end

    agent
    |> Intelligence.known_waypoints(system)
    |> Enum.map(&waypoint(&1, system, as_of, freshness_seconds, facts))
  end

  defp waypoint(symbol, system, as_of, freshness_seconds, facts) do
    project = fn type, budget ->
      projection(type, system, symbol, facts.(type, symbol), as_of, budget)
    end

    project.(:waypoint, freshness_seconds)
    |> Map.put(:symbol, symbol)
    |> Map.put(:market, project.(:market, Intelligence.market_freshness_seconds()))
    |> Map.put(:shipyard, project.(:shipyard, freshness_seconds))
    |> Map.put(:construction, project.(:construction, freshness_seconds))
  end

  @doc """
  Known Waypoint coordinates in `system`. Coordinates are static game facts,
  so any retained observation of them counts, however old.

  Standalone form of `projections/4`'s `:waypoint_coordinates`.
  """
  def waypoint_coordinates(%AgentRecord{} = agent, system) when is_binary(system) do
    %{waypoint_coordinates: coordinates} =
      projections(agent, system, DateTime.utc_now(), @fuel_listing_freshness_seconds)

    coordinates
  end

  defp coordinates(symbols, waypoint_facts) do
    for symbol <- symbols,
        facts = waypoint_facts.(symbol),
        %{state: "known", value: x} when is_integer(x) <- [facts["x"]],
        %{state: "known", value: y} when is_integer(y) <- [facts["y"]],
        into: %{},
        do: {symbol, %{x: x, y: y}}
  end

  @doc """
  The confirmed fuel stops in `system` at `as_of`, sorted by symbol: Waypoints
  with known coordinates whose Market Listing, fresh at `as_of`, sells FUEL.
  Standalone form of `projections/4`'s `:fuel_stops`, which carries the rule.
  """
  def fuel_stops(%AgentRecord{} = agent, system, %DateTime{} = as_of) when is_binary(system) do
    %{fuel_stops: fuel_stops} =
      projections(agent, system, as_of, @fuel_listing_freshness_seconds)

    Enum.sort(fuel_stops)
  end

  defp sells_fresh_fuel?(market) do
    case market.facts["trade_goods"] do
      %{freshness: :fresh, value: goods} when is_list(goods) ->
        Enum.any?(goods, &(Map.get(&1, "symbol") == "FUEL"))

      _ ->
        false
    end
  end

  def intelligence(%AgentRecord{} = agent, type, system, symbol, as_of, freshness_seconds)
      when type in @subject_types and is_binary(system) and
             is_binary(symbol) and is_struct(as_of, DateTime) and
             is_integer(freshness_seconds) and freshness_seconds >= 0 do
    facts = Intelligence.subject(agent, type, system, symbol)
    projection(type, system, symbol, facts, as_of, freshness_seconds)
  end

  defp projection(type, system, symbol, facts, as_of, freshness_seconds) do
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
