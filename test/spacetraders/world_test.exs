defmodule SpaceTraders.WorldTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.API.Model.{Construction, Market, Shipyard, Waypoint}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Repo
  alias SpaceTraders.World

  test "known Waypoints remain visible when Market Listings age out or are unavailable" do
    agent =
      Repo.insert!(%AgentRecord{
        symbol: "WORLD-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    waypoint =
      Waypoint.from_json(%{
        "symbol" => "X1-A1",
        "systemSymbol" => "X1",
        "type" => "PLANET",
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    market = Market.from_json(%{"symbol" => "X1-A1", "exports" => [%{"symbol" => "IRON"}]})

    assert {:ok, _} =
             Intelligence.observe_waypoint(agent, waypoint,
               source: "get_waypoints",
               observed_at: ~U[2030-01-01 11:00:00Z]
             )

    assert {:ok, _} =
             Intelligence.observe_market(agent, "X1", market,
               source: "get_market",
               observed_at: ~U[2030-01-01 11:00:00Z]
             )

    assert [entry] = World.waypoints(agent, "X1", ~U[2030-01-01 12:00:00Z], 300)
    assert entry.symbol == "X1-A1"
    assert entry.known_existence?
    assert entry.facts["traits"].freshness == :stale
    assert entry.market.facts["exports"].freshness == :stale
    assert entry.market.facts["trade_goods"] == nil
    assert entry.market.facts["exports"].source == "Market observation"
    assert entry.market.facts["exports"].observed_at == ~U[2030-01-01 11:00:00Z]

    assert {:ok, _} =
             Intelligence.mark_unavailable(agent, "market", "X1", "X1-A1", [:trade_goods],
               source: "get_market",
               observed_at: ~U[2030-01-01 12:00:00Z]
             )

    assert [entry] = World.waypoints(agent, "X1", ~U[2030-01-01 12:00:00Z], 300)
    assert entry.market.facts["trade_goods"].state == "known_unavailable"
    assert entry.market.facts["trade_goods"].freshness == :not_established
    assert entry.market.facts["trade_goods"].value == nil

    assert {:ok, _} = Intelligence.invalidate(agent, :waypoint, "X1", "X1-A1")
    assert [known] = World.waypoints(agent, "X1", ~U[2030-01-01 12:00:00Z], 300)
    assert known.known_existence?
    assert known.facts["traits"] == nil
  end

  # #662: Fleet Planning and Ship Execution judge fuel reach from this one
  # answer, so a stop one accepts the other cannot refuse.
  test "fuel stops: static coordinates of any age, FUEL only on a fresh Listing" do
    agent =
      Repo.insert!(%AgentRecord{
        symbol: "FUEL-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    old = ~U[2030-01-01 09:00:00Z]
    now = ~U[2030-01-01 12:00:00Z]

    for {symbol, x, listed_at} <- [
          {"X1-FRESH", 10, ~U[2030-01-01 11:40:00Z]},
          {"X1-STALE", 20, ~U[2030-01-01 11:29:00Z]}
        ] do
      waypoint =
        Waypoint.from_json(%{
          "symbol" => symbol,
          "systemSymbol" => "X1",
          "type" => "PLANET",
          "x" => x,
          "y" => 0,
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        })

      assert {:ok, _} =
               Intelligence.observe_waypoint(agent, waypoint,
                 source: "get_waypoints",
                 observed_at: old
               )

      market =
        Market.from_json(%{
          "symbol" => symbol,
          "exchange" => [%{"symbol" => "FUEL"}],
          "tradeGoods" => [
            %{
              "symbol" => "FUEL",
              "type" => "EXCHANGE",
              "tradeVolume" => 10,
              "purchasePrice" => 72,
              "sellPrice" => 68
            }
          ]
        })

      assert {:ok, _} =
               Intelligence.observe_market(agent, "X1", market,
                 source: "get_market",
                 observing_ship_symbol: "FUEL-1",
                 observed_at: listed_at
               )
    end

    assert World.fuel_stops(agent, "X1", now) == ["X1-FRESH"]

    assert World.waypoint_coordinates(agent, "X1") == %{
             "X1-FRESH" => %{x: 10, y: 0},
             "X1-STALE" => %{x: 20, y: 0}
           }
  end

  test "Shipyard offerings retain the observing Ship and do not imply absent data" do
    agent =
      Repo.insert!(%AgentRecord{
        symbol: "YARD-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    shipyard = Shipyard.from_json(%{"symbol" => "X1-A1", "shipTypes" => []})

    assert {:ok, _} =
             Intelligence.observe_shipyard(agent, "X1", shipyard,
               source: "get_shipyard",
               observing_ship_symbol: "YARD-1",
               observed_at: ~U[2030-01-01 12:00:00Z]
             )

    projection =
      World.intelligence(agent, :shipyard, "X1", "X1-A1", ~U[2030-01-01 12:00:01Z], 300)

    assert projection.facts["ship_types"].value == []
    assert projection.facts["ship_types"].observing_ship_symbol == "YARD-1"
    assert projection.facts["ships"].state == "unknown"
    assert projection.facts["ships"].value == nil

    assert Shipyard.from_json(%{"symbol" => "X1-A1", "shipTypes" => []}).ships == nil

    assert Shipyard.from_json(%{"symbol" => "X1-A1", "shipTypes" => [], "ships" => []}).ships ==
             []

    assert Market.from_json(%{"symbol" => "X1-A1"}).trade_goods == nil
    assert Market.from_json(%{"symbol" => "X1-A1", "tradeGoods" => []}).trade_goods == []
  end

  test "unavailable Construction evidence does not establish a Construction project" do
    agent =
      Repo.insert!(%AgentRecord{
        symbol: "CONSTRUCTION-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-A1"
      })

    assert {:ok, _} =
             Intelligence.mark_unavailable(agent, :construction, "X1", "X1-A1", [:complete],
               source: "get_construction",
               observed_at: ~U[2030-01-01 12:00:00Z]
             )

    construction =
      World.intelligence(agent, :construction, "X1", "X1-A1", ~U[2030-01-01 12:00:01Z], 300)

    refute construction.known_existence?
    assert construction.facts["complete"].state == "known_unavailable"
  end

  describe "projections/4 combined read" do
    @as_of ~U[2030-01-01 12:00:00Z]

    test "returns the standalone Waypoint, coordinate and fuel-stop projections with original provenance" do
      agent = world_agent("COMBINED")

      # X1-A: old complete coordinates survive a newer partial observation
      # that omits them; a fresh FUEL Listing under the 1,800-second Market
      # budget, though older than the 300-second non-Market budget.
      {:ok, a_coordinates} =
        observe(agent, "X1-A", %{"type" => "PLANET", "x" => 10, "y" => 0, "orbits" => "X1-P"},
          source: "get_waypoints",
          observed_at: ~U[2030-01-01 09:00:00Z]
        )

      {:ok, a_partial} =
        observe(agent, "X1-A", %{"type" => "MOON"},
          source: "get_waypoint",
          observing_ship_symbol: "SCOUT-1",
          observed_at: ~U[2030-01-01 11:58:00Z]
        )

      {:ok, a_listing} = listing(agent, "X1-A", ["FUEL"], ~U[2030-01-01 11:40:00Z])

      {:ok, _} =
        Intelligence.observe_shipyard(
          agent,
          "X1",
          Shipyard.from_json(%{"symbol" => "X1-A", "shipTypes" => []}),
          source: "get_shipyard",
          observing_ship_symbol: "SCOUT-1",
          observed_at: ~U[2030-01-01 11:59:00Z]
        )

      {:ok, a_construction} =
        Intelligence.observe_construction(
          agent,
          "X1",
          Construction.from_json(%{"symbol" => "X1-A", "isComplete" => false, "materials" => []}),
          source: "get_construction",
          observed_at: ~U[2030-01-01 11:59:00Z]
        )

      # X1-B: a stale FUEL Listing is not a fuel stop.
      {:ok, _} = observe(agent, "X1-B", %{"x" => 20, "y" => 5})
      {:ok, _} = listing(agent, "X1-B", ["FUEL"], ~U[2030-01-01 11:29:00Z])

      # X1-C: incomplete coordinates exclude it, despite a fresh FUEL Listing.
      {:ok, _} = observe(agent, "X1-C", %{"x" => 25})
      {:ok, _} = listing(agent, "X1-C", ["FUEL"], ~U[2030-01-01 11:50:00Z])

      # X1-D: a fresh Listing without FUEL; known-unavailable Construction
      # alone establishes no project.
      {:ok, _} = observe(agent, "X1-D", %{"x" => 30, "y" => 0})
      {:ok, _} = listing(agent, "X1-D", ["IRON"], ~U[2030-01-01 11:50:00Z])

      {:ok, _} =
        Intelligence.mark_unavailable(agent, :construction, "X1", "X1-D", [:complete],
          source: "get_construction",
          observed_at: ~U[2030-01-01 11:50:00Z]
        )

      # X1-E: future observations keep current behavior: stale, never fresh.
      {:ok, _} =
        observe(agent, "X1-E", %{"x" => 40, "y" => 0, "traits" => []},
          source: "get_waypoints",
          observed_at: ~U[2030-01-01 12:10:00Z]
        )

      {:ok, _} = listing(agent, "X1-E", ["FUEL"], ~U[2030-01-01 12:10:00Z])

      # X1-F: still a known Waypoint although its selected symbol fact is
      # now known-unavailable.
      {:ok, _} = observe(agent, "X1-F", %{"x" => 50, "y" => 0})

      {:ok, _} =
        Intelligence.mark_unavailable(agent, :waypoint, "X1", "X1-F", [:symbol],
          source: "get_waypoint",
          observed_at: ~U[2030-01-01 11:00:00Z]
        )

      # X1-G: non-integer coordinates are unusable.
      {:ok, _} = observe(agent, "X1-G", %{"x" => 1.5, "y" => 2})

      # Identical symbols in another System and for another Agent never mix.
      {:ok, _} = observe(agent, "X1-A", %{"x" => 77, "y" => 77}, system: "X2")
      other = world_agent("OTHER")
      {:ok, _} = observe(other, "X1-A", %{"x" => 88, "y" => 88})
      {:ok, _} = listing(other, "X1-B", ["FUEL"], ~U[2030-01-01 11:59:00Z])

      result = World.projections(agent, "X1", @as_of, 300)

      assert result |> Map.keys() |> Enum.sort() ==
               [:fuel_stops, :waypoint_coordinates, :waypoints]

      assert result.waypoint_coordinates == %{
               "X1-A" => %{x: 10, y: 0},
               "X1-B" => %{x: 20, y: 5},
               "X1-D" => %{x: 30, y: 0},
               "X1-E" => %{x: 40, y: 0},
               "X1-F" => %{x: 50, y: 0}
             }

      assert result.fuel_stops == ["X1-A"]

      assert Enum.map(result.waypoints, & &1.symbol) ==
               ["X1-A", "X1-B", "X1-C", "X1-D", "X1-E", "X1-F", "X1-G"]

      [a, _b, _c, d, e, f, _g] = result.waypoints

      assert a.subject == {:waypoint, "X1", "X1-A"}
      assert a.known_existence?

      assert a.facts["x"] == %{
               state: "known",
               value: 10,
               freshness: :stale,
               observed_at: ~U[2030-01-01 09:00:00Z],
               observation_id: a_coordinates.id,
               source: "Public Waypoint observation",
               observing_ship_symbol: nil
             }

      assert %{value: "MOON", freshness: :fresh, observation_id: a_partial_id} = a.facts["type"]
      assert a_partial_id == a_partial.id
      assert a.facts["type"].observing_ship_symbol == "SCOUT-1"
      assert %{state: "known", value: "X1-P", freshness: :stale} = a.facts["orbits"]

      assert %{state: "unknown", value: nil, freshness: :not_established} = a.facts["chart"]
      assert a.facts["chart"].observation_id == a_partial.id

      assert a.market.subject == {:market, "X1", "X1-A"}
      assert a.market.known_existence?

      assert %{freshness: :fresh, value: [%{"symbol" => "FUEL"}]} =
               a.market.facts["trade_goods"]

      assert a.market.facts["trade_goods"].observation_id == a_listing.id
      assert a.market.facts["trade_goods"].source == "Market observation"
      assert a.market.facts["trade_goods"].observing_ship_symbol == "LISTER-1"

      assert %{value: [], freshness: :fresh, source: "Shipyard observation"} =
               a.shipyard.facts["ship_types"]

      assert %{state: "unknown", value: nil} = a.shipyard.facts["ships"]

      assert a.construction.known_existence?

      assert %{state: "known", value: false, freshness: :fresh} =
               a.construction.facts["complete"]

      assert a.construction.facts["complete"].observation_id == a_construction.id

      refute d.construction.known_existence?
      assert d.construction.facts["complete"].state == "known_unavailable"

      assert d.shipyard == %{
               subject: {:shipyard, "X1", "X1-D"},
               known_existence?: false,
               facts: %{}
             }

      assert e.facts["traits"].freshness == :stale
      assert e.market.facts["trade_goods"].freshness == :stale

      refute f.known_existence?
      assert f.facts["symbol"].state == "known_unavailable"

      assert result.waypoints == World.waypoints(agent, "X1", @as_of, 300)
      assert result.waypoint_coordinates == World.waypoint_coordinates(agent, "X1")
      assert result.fuel_stops == World.fuel_stops(agent, "X1", @as_of)

      # An explicit read for another (e.g. historical) Agent uses only its facts.
      other_result = World.projections(other, "X1", @as_of, 300)
      assert other_result.waypoint_coordinates == %{"X1-A" => %{x: 88, y: 88}}
      assert other_result.fuel_stops == []
      assert Enum.map(other_result.waypoints, & &1.symbol) == ["X1-A"]

      assert World.projections(agent, "X2", @as_of, 300).waypoint_coordinates ==
               %{"X1-A" => %{x: 77, y: 77}}
    end

    test "an empty System reads nothing more than known-symbol discovery" do
      agent = world_agent("EMPTY")

      {result, queries} = measure(fn -> World.projections(agent, "X1", @as_of, 300) end)

      assert result == %{waypoints: [], waypoint_coordinates: %{}, fuel_stops: []}
      assert length(queries) <= 1
    end

    # Proves SELECT count only: not bounded rows, memory, latency or HTTP.
    test "SELECT count stays within two and does not grow with Waypoints or history" do
      small = world_agent("SMALL")
      large = world_agent("LARGE")

      seed_system(small, 2, 1)
      seed_system(large, 12, 4)

      {small_result, small_queries} =
        measure(fn -> World.projections(small, "X1", @as_of, 300) end)

      {large_result, large_queries} =
        measure(fn -> World.projections(large, "X1", @as_of, 300) end)

      # Nonzero proves the scoped handler observed the read.
      assert length(small_queries) in 1..2
      assert length(large_queries) == length(small_queries)
      assert Enum.all?(small_queries ++ large_queries, &String.starts_with?(&1, "SELECT"))

      assert small_result.fuel_stops == ["X1-W00"]

      assert small_result.waypoint_coordinates == %{
               "X1-W00" => %{x: 0, y: 3},
               "X1-W01" => %{x: 1, y: 3}
             }

      assert large_result.fuel_stops ==
               ["X1-W00", "X1-W02", "X1-W04", "X1-W06", "X1-W08", "X1-W10"]

      assert map_size(large_result.waypoint_coordinates) == 12
      assert large_result.waypoint_coordinates["X1-W11"] == %{x: 11, y: 3}

      [w00 | _] = large_result.waypoints
      # The newest observation omitted coordinates; the older one supplies them.
      assert w00.facts["x"].observed_at == ~U[2030-01-01 08:00:00Z]
      assert w00.facts["type"].observed_at == ~U[2030-01-01 11:04:00Z]
      assert w00.market.facts["trade_goods"].observed_at == ~U[2030-01-01 11:50:00Z]
      assert w00.market.facts["trade_goods"].observing_ship_symbol == "LISTER-1"
      assert w00.shipyard.known_existence?
      assert w00.construction.known_existence?

      assert large_result == %{
               waypoints: World.waypoints(large, "X1", @as_of, 300),
               waypoint_coordinates: World.waypoint_coordinates(large, "X1"),
               fuel_stops: World.fuel_stops(large, "X1", @as_of)
             }
    end

    test "a later read reflects new observations, invalidation and Agent identity" do
      agent = world_agent("LATER")
      {:ok, _} = observe(agent, "X1-A", %{"x" => 1, "y" => 1})
      {:ok, _} = listing(agent, "X1-A", ["FUEL"], ~U[2030-01-01 11:50:00Z])

      assert %{fuel_stops: ["X1-A"], waypoint_coordinates: %{"X1-A" => %{x: 1, y: 1}}} =
               World.projections(agent, "X1", @as_of, 300)

      {:ok, _} = observe(agent, "X1-B", %{"x" => 2, "y" => 2})
      {:ok, _} = Intelligence.invalidate(agent, :market, "X1", "X1-A")

      assert %{fuel_stops: [], waypoint_coordinates: coordinates} =
               World.projections(agent, "X1", @as_of, 300)

      assert coordinates == %{"X1-A" => %{x: 1, y: 1}, "X1-B" => %{x: 2, y: 2}}

      successor = world_agent("SUCCESSOR")

      assert World.projections(successor, "X1", @as_of, 300) ==
               %{waypoints: [], waypoint_coordinates: %{}, fuel_stops: []}
    end
  end

  test "projections for an explicit historical Agent never substitute the current Agent" do
    import SpaceTraders.AgentFixtures
    operator = operator_fixture()

    historical = agent_fixture(operator, %{symbol: "HIST", publish: false})

    generation_fixture(%SpaceTraders.FleetGeneration.Generation{
      operator_id: operator.id,
      agent_id: historical.id,
      number: 1,
      symbol: "HIST",
      faction: "COSMIC",
      fenced_at: DateTime.add(DateTime.utc_now(), -7200),
      retired_at: DateTime.add(DateTime.utc_now(), -3600)
    })

    current = agent_fixture(operator, %{symbol: "CURR"})

    {:ok, _} = observe(historical, "X1-H", %{"x" => 1, "y" => 1})
    {:ok, _} = listing(historical, "X1-H", ["FUEL"], ~U[2030-01-01 11:50:00Z])
    {:ok, _} = observe(current, "X1-C", %{"x" => 9, "y" => 9})

    assert %{waypoint_coordinates: %{"X1-H" => %{x: 1, y: 1}} = coordinates, fuel_stops: ["X1-H"]} =
             World.projections(historical, "X1", @as_of, 300)

    assert Map.keys(coordinates) == ["X1-H"]

    assert %{waypoint_coordinates: %{"X1-C" => %{x: 9, y: 9}} = current_coordinates, fuel_stops: []} =
             World.projections(current, "X1", @as_of, 300)

    assert Map.keys(current_coordinates) == ["X1-C"]
  end

  defp world_agent(prefix) do
    Repo.insert!(%AgentRecord{
      symbol: "#{prefix}-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-A"
    })
  end

  defp observe(agent, symbol, attrs, opts \\ []) do
    {system, opts} = Keyword.pop(opts, :system, "X1")

    waypoint =
      Waypoint.from_json(Map.merge(%{"symbol" => symbol, "systemSymbol" => system}, attrs))

    Intelligence.observe_waypoint(
      agent,
      waypoint,
      Keyword.merge([source: "get_waypoints", observed_at: ~U[2030-01-01 08:00:00Z]], opts)
    )
  end

  defp listing(agent, symbol, goods, observed_at) do
    market =
      Market.from_json(%{
        "symbol" => symbol,
        "tradeGoods" =>
          Enum.map(goods, fn good ->
            %{
              "symbol" => good,
              "type" => "EXCHANGE",
              "tradeVolume" => 10,
              "purchasePrice" => 72,
              "sellPrice" => 68
            }
          end)
      })

    Intelligence.observe_market(agent, "X1", market,
      source: "get_market",
      observing_ship_symbol: "LISTER-1",
      observed_at: observed_at
    )
  end

  # Every World subject type per Waypoint, `history` later partial Waypoint
  # observations that omit coordinates, an older Listing, and a fresh one
  # selling FUEL at even Waypoints.
  defp seed_system(agent, count, history) do
    for index <- 0..(count - 1) do
      symbol = "X1-W" <> String.pad_leading(Integer.to_string(index), 2, "0")
      {:ok, _} = observe(agent, symbol, %{"type" => "PLANET", "x" => index, "y" => 3})

      for step <- 1..history do
        {:ok, _} =
          observe(agent, symbol, %{"type" => "MOON"},
            source: "get_waypoint",
            observed_at: DateTime.add(~U[2030-01-01 11:00:00Z], step * 60)
          )
      end

      {:ok, _} = listing(agent, symbol, ["FUEL"], ~U[2030-01-01 10:00:00Z])

      fuel = if rem(index, 2) == 0, do: ["FUEL"], else: ["IRON"]
      {:ok, _} = listing(agent, symbol, fuel, ~U[2030-01-01 11:50:00Z])

      {:ok, _} =
        Intelligence.observe_shipyard(
          agent,
          "X1",
          Shipyard.from_json(%{"symbol" => symbol, "shipTypes" => []}),
          source: "get_shipyard",
          observed_at: ~U[2030-01-01 11:50:00Z]
        )

      {:ok, _} =
        Intelligence.observe_construction(
          agent,
          "X1",
          Construction.from_json(%{"symbol" => symbol, "isComplete" => false, "materials" => []}),
          source: "get_construction",
          observed_at: ~U[2030-01-01 11:50:00Z]
        )
    end
  end

  # Repo queries issued by this test process only, while `fun` runs. Ecto
  # derives the event prefix from `SpaceTraders.Repo`: `[:space_traders, :repo]`.
  defp measure(fun) do
    handler = "world-projections-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:space_traders, :repo, :query],
        &__MODULE__.capture_query/4,
        test_pid
      )

    try do
      result = fun.()
      {result, collect_queries([])}
    after
      :telemetry.detach(handler)
    end
  end

  def capture_query(_event, _measurements, %{query: query}, test_pid) do
    if self() == test_pid, do: send(test_pid, {:world_query, query})
  end

  defp collect_queries(queries) do
    receive do
      {:world_query, query} -> collect_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
