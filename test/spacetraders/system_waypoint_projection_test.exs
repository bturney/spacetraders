defmodule SpaceTraders.SystemWaypointProjectionTest do
  use ExUnit.Case, async: true

  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model.{Ship, Waypoint}
  alias SpaceTraders.SystemWaypointProjection

  describe "project/5" do
    test "exposes every waypoint for the grid and positions coordinate-bearing ones" do
      projection = project(waypoints())

      assert projection.waypoints == {:ok, Enum.map(waypoints(), &Waypoint.from_json/1)}

      assert Enum.map(projection.available, & &1.symbol) ==
               ["X1-UX81-A1", "X1-UX81-A3", "X1-UX81-B1", "X1-UX81-B2", "X1-UX81-C1"]

      assert Enum.map(projection.positioned, & &1.symbol) ==
               ["X1-UX81-A1", "X1-UX81-A3", "X1-UX81-B1", "X1-UX81-B2"]

      assert Enum.all?(projection.positioned, &(is_integer(&1.x) and is_integer(&1.y)))
      refute Enum.any?(projection.positioned, &(&1.symbol == "X1-UX81-C1"))
    end

    test "stacks orbital waypoints on their parent regardless of list order" do
      projection = project(Enum.reverse(waypoints()))

      b1 = waypoint_by_symbol(projection.positioned, "X1-UX81-B1")
      b2 = waypoint_by_symbol(projection.positioned, "X1-UX81-B2")

      assert b1.orbital_count == 1
      assert b1.orbital_index == nil

      assert b2.orbital_count == 1
      assert b2.orbital_index == 0
    end

    test "treats an orbital as standalone when its parent has no coordinates" do
      waypoints = [
        waypoint_json("X1-UX81-A1", %{"type" => "ORBITAL_STATION", "x" => -12, "y" => 8}),
        waypoint_json("X1-UX81-O1", %{
          "type" => "MOON",
          "x" => 4,
          "y" => 19,
          "orbits" => "X1-UX81-C1"
        })
      ]

      positioned = project(waypoints).positioned
      o1 = waypoint_by_symbol(positioned, "X1-UX81-O1")

      assert o1.orbital_index == nil
      assert o1.orbital_count == 0
    end

    test "filters grid waypoints by type and trait, leaving the map full" do
      projection = project(waypoints(), filter: "marketplace")
      assert Enum.map(projection.filtered, & &1.symbol) == ["X1-UX81-A1", "X1-UX81-B1"]
      assert length(projection.positioned) == 4

      projection = project(waypoints(), filter: "engineered_asteroid")
      assert Enum.map(projection.filtered, & &1.symbol) == ["X1-UX81-A3"]

      projection = project(waypoints(), filter: "all")
      assert length(projection.filtered) == 5
    end

    test "counts only local ships at each waypoint" do
      ships = [
        ship("ORBITALIST-1", "X1-UX81-A1", "IN_ORBIT"),
        ship("ORBITALIST-2", "X1-UX81-A1", "DOCKED"),
        ship("ORBITALIST-3", "X1-UX81-A3", "IN_TRANSIT"),
        ship("ORBITALIST-4", "X1-UX81-A3", "IN_ORBIT", system: "X1-OTHER"),
        ship("ORBITALIST-5", "X1-OTHER-A1", "IN_ORBIT")
      ]

      ships_at = project(waypoints(), ships: ships).ships_at

      assert Enum.map(ships_at["X1-UX81-A1"], & &1.symbol) == ["ORBITALIST-1", "ORBITALIST-2"]
      assert ships_at["X1-UX81-A3"] == []
      assert ships_at["X1-UX81-B1"] == []
    end

    test "marks ship state unavailable when the fleet read fails" do
      projection = project(waypoints(), ships: {:error, :agent_token_missing})

      assert projection.ships_at == :unavailable
      assert projection.transit_routes == []
      assert projection.off_system == []
      assert projection.inter_system_transit == []
    end

    test "projects transit routes for in-transit ships inside the system" do
      transit = ship("ORBITALIST-3", "X1-UX81-A3", "IN_TRANSIT")
      projection = project(waypoints(), ships: [transit])

      assert [%{ship: ship, origin: origin, destination: destination}] = projection.transit_routes
      assert ship.symbol == "ORBITALIST-3"
      assert origin.symbol == "X1-UX81-A1"
      assert destination.symbol == "X1-UX81-A3"
    end

    test "excludes routes whose endpoints have no coordinates" do
      transit = ship("ORBITALIST-3", "X1-UX81-C1", "IN_TRANSIT", origin: "X1-UX81-C1")
      projection = project(waypoints(), ships: [transit])
      assert projection.transit_routes == []
    end

    test "reports off-system ships and inter-system transit separately" do
      ships = [
        ship("ORBITALIST-1", "X1-UX81-A1", "IN_ORBIT"),
        ship("ORBITALIST-2", "X1-UX81-A1", "IN_TRANSIT"),
        ship("ORBITALIST-4", "X1-OTHER-A1", "IN_ORBIT", system: "X1-OTHER"),
        ship("ORBITALIST-5", "X1-OTHER-A2", "IN_TRANSIT",
          system: "X1-OTHER",
          origin: "X1-OTHER-A1"
        ),
        ship("ORBITALIST-6", "X1-OTHER-A1", "IN_TRANSIT",
          origin: "X1-OTHER-A1",
          destination: "X1-UX81-A1"
        )
      ]

      projection = project(waypoints(), ships: ships, system_symbol: "X1-UX81")

      assert Enum.map(projection.off_system, & &1.symbol) ==
               ["ORBITALIST-4", "ORBITALIST-5"]

      assert Enum.map(projection.inter_system_transit, & &1.symbol) == ["ORBITALIST-6"]
    end

    test "resolves the selected waypoint" do
      projection = project(waypoints(), selected_symbol: "X1-UX81-B2")

      assert projection.selected.symbol == "X1-UX81-B2"
      assert project(waypoints(), selected_symbol: "X1-UX81-Z9").selected == nil
    end

    test "preserves unavailable waypoints and empties derived state" do
      projection =
        SystemWaypointProjection.project({:error, :invalid_headquarters}, {:ok, []}, nil)

      assert projection.waypoints == {:error, :invalid_headquarters}
      assert projection.available == []
      assert projection.filtered == []
      assert projection.positioned == []
      assert projection.selected == nil
      assert projection.ships_at == :unavailable
      assert projection.transit_routes == []
      assert projection.off_system == []
      assert projection.inter_system_transit == []
    end

    test "filter options are exactly the values project/5 interprets" do
      assert Enum.map(SystemWaypointProjection.filter_options(), &elem(&1, 1)) == [
               "all",
               "engineered_asteroid",
               "shipyard",
               "marketplace"
             ]
    end
  end

  defp project(waypoints_json, opts \\ []) do
    waypoints = Enum.map(waypoints_json, &Waypoint.from_json/1)

    ships =
      case Keyword.get(opts, :ships, []) do
        {:error, _reason} = error -> error
        ships when is_list(ships) -> {:ok, Enum.map(ships, &Ship.from_json/1)}
      end

    SystemWaypointProjection.project(
      {:ok, waypoints},
      ships,
      Keyword.get(opts, :system_symbol, "X1-UX81"),
      Keyword.get(opts, :selected_symbol, nil),
      Keyword.get(opts, :filter, "all")
    )
  end

  defp waypoints do
    [
      waypoint_json("X1-UX81-A1", %{
        "type" => "ORBITAL_STATION",
        "x" => -12,
        "y" => 8,
        "traits" => [%{"symbol" => "MARKETPLACE"}, %{"symbol" => "SHIPYARD"}]
      }),
      waypoint_json("X1-UX81-A3", %{
        "type" => "ENGINEERED_ASTEROID",
        "x" => 14,
        "y" => -6,
        "traits" => [%{"symbol" => "MINERAL_DEPOSITS"}]
      }),
      waypoint_json("X1-UX81-B1", %{
        "type" => "PLANET",
        "x" => 4,
        "y" => 19,
        "traits" => [%{"symbol" => "MARKETPLACE"}],
        "orbitals" => [%{"symbol" => "X1-UX81-B2"}]
      }),
      waypoint_json("X1-UX81-B2", %{
        "type" => "MOON",
        "x" => 4,
        "y" => 19,
        "orbits" => "X1-UX81-B1"
      }),
      waypoint_json("X1-UX81-C1", %{"type" => "JUMP_GATE", "x" => nil, "y" => nil})
    ]
  end

  defp waypoint_json(symbol, overrides) do
    Map.merge(
      %{
        "symbol" => symbol,
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 0,
        "y" => 0,
        "traits" => []
      },
      overrides
    )
  end

  defp ship(symbol, waypoint, status, opts \\ []) do
    system = Keyword.get(opts, :system, "X1-UX81")
    origin = Keyword.get(opts, :origin, "X1-UX81-A1")
    destination = Keyword.get(opts, :destination, waypoint)

    ship_body(symbol, %{
      "nav" => %{
        "systemSymbol" => system,
        "waypointSymbol" => waypoint,
        "status" => status,
        "flightMode" => "CRUISE",
        "route" => %{
          "origin" => %{"symbol" => origin, "systemSymbol" => system_of(origin)},
          "destination" => %{"symbol" => destination, "systemSymbol" => system_of(destination)},
          "departureTime" => "2026-01-01T00:00:00.000Z",
          "arrival" => "2026-01-01T00:05:00.000Z"
        }
      }
    })
  end

  defp system_of(symbol), do: symbol |> String.split("-") |> Enum.take(2) |> Enum.join("-")

  defp waypoint_by_symbol(waypoints, symbol), do: Enum.find(waypoints, &(&1.symbol == symbol))
end
