defmodule SpaceTraders.WorldTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.API.Model.{Market, Shipyard, Waypoint}
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
          {"X1-FRESH", 10, ~U[2030-01-01 11:58:00Z]},
          {"X1-STALE", 20, ~U[2030-01-01 11:00:00Z]}
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
end
