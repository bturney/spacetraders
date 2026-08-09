defmodule SpaceTraders.ShipyardTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Shipyard

  defp agent_fixture do
    Repo.insert!(%AgentRecord{
      symbol: "SHIPYARD-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN"
    })
  end

  defp waypoint_body(symbol) do
    %{
      "symbol" => symbol,
      "systemSymbol" => "X1-UX81",
      "type" => "ORBITAL_STATION",
      "x" => 1,
      "y" => 2,
      "traits" => [%{"symbol" => "SHIPYARD", "name" => "Shipyard", "description" => ""}]
    }
  end

  test "discovers shipyards in the agent's headquarters system" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/systems/X1-UX81/waypoints"
      assert conn.query_params == %{"traits" => "SHIPYARD"}
      Req.Test.json(conn, %{"data" => [waypoint_body("X1-UX81-A2")]})
    end)

    assert {:ok, [%Model.Waypoint{symbol: "X1-UX81-A2"}]} = Shipyard.discover(agent_fixture())
  end

  test "loads listings only for a ship currently on a discovered shipyard" do
    ship = %Model.Ship{
      symbol: "ORBITALIST-1",
      nav: %Model.ShipNav{
        status: "DOCKED",
        system_symbol: "X1-UX81",
        waypoint_symbol: "X1-UX81-A2"
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/systems/X1-UX81/waypoints" ->
          Req.Test.json(conn, %{"data" => [waypoint_body("X1-UX81-A2")]})

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/shipyard" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "modificationsFee" => 100,
              "shipTypes" => [%{"type" => "SHIP_MINING_DRONE"}],
              "ships" => [
                %{"type" => "SHIP_MINING_DRONE", "name" => "Mining Drone", "purchasePrice" => 50}
              ]
            }
          })
      end
    end)

    assert {:ok, [%{waypoint: "X1-UX81-A2", shipyard: %Model.Shipyard{symbol: "X1-UX81-A2"}}]} =
             Shipyard.listings(agent_fixture(), [ship])
  end

  test "loads docked shipyard listings across systems in waypoint order" do
    ships = [
      %Model.Ship{
        symbol: "SECOND",
        nav: %Model.ShipNav{
          status: "DOCKED",
          system_symbol: "X1-UX82",
          waypoint_symbol: "X1-UX82-A1"
        }
      },
      %Model.Ship{
        symbol: "FIRST",
        nav: %Model.ShipNav{
          status: "DOCKED",
          system_symbol: "X1-UX81",
          waypoint_symbol: "X1-UX81-A2"
        }
      }
    ]

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/systems/X1-UX81/waypoints" ->
          Req.Test.json(conn, %{"data" => [waypoint_body("X1-UX81-A2")]})

        "/v2/systems/X1-UX82/waypoints" ->
          Req.Test.json(conn, %{
            "data" => [Map.put(waypoint_body("X1-UX82-A1"), "systemSymbol", "X1-UX82")]
          })

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/shipyard" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-A2"}})

        "/v2/systems/X1-UX82/waypoints/X1-UX82-A1/shipyard" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX82-A1"}})
      end
    end)

    assert {:ok, listings} = Shipyard.listings(agent_fixture(), ships)
    assert Enum.map(listings, & &1.waypoint) == ["X1-UX81-A2", "X1-UX82-A1"]
  end

  test "reports a generic error when a shipyard listing is unavailable" do
    ship = %Model.Ship{
      symbol: "ORBITALIST-1",
      nav: %Model.ShipNav{
        status: "DOCKED",
        system_symbol: "X1-UX81",
        waypoint_symbol: "X1-UX81-A2"
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/systems/X1-UX81/waypoints" ->
          Req.Test.json(conn, %{"data" => [waypoint_body("X1-UX81-A2")]})

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/shipyard" ->
          conn
          |> Plug.Conn.put_status(503)
          |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})
      end
    end)

    assert {:partial, []} = Shipyard.listings(agent_fixture(), [ship])
  end

  test "purchases a ship through the agent token" do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/ships"

      assert conn.body_params == %{
               "shipType" => "SHIP_MINING_DRONE",
               "waypointSymbol" => "X1-UX81-A2"
             }

      Req.Test.json(conn, %{"data" => %{"agent" => %{}, "ship" => %{}, "transaction" => %{}}})
    end)

    assert {:ok, %{transaction: %Model.ShipyardTransaction{}, ship: %Model.Ship{}}} =
             Shipyard.purchase(agent_fixture(), "SHIP_MINING_DRONE", "X1-UX81-A2")
  end
end
