defmodule SpaceTraders.FleetTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet

  defp ship_body(symbol, overrides \\ %{}) do
    Map.merge(
      %{
        "symbol" => symbol,
        "registration" => %{
          "name" => symbol,
          "factionSymbol" => "COSMIC",
          "role" => "COMMAND"
        },
        "nav" => %{
          "systemSymbol" => "X1-UX81",
          "waypointSymbol" => "X1-UX81-A1",
          "status" => "DOCKED",
          "flightMode" => "CRUISE",
          "route" => %{
            "destination" => %{
              "symbol" => "X1-UX81-A1",
              "type" => "PLANET",
              "systemSymbol" => "X1-UX81",
              "x" => 1,
              "y" => 2
            },
            "origin" => %{
              "symbol" => "X1-UX81-A1",
              "type" => "PLANET",
              "systemSymbol" => "X1-UX81",
              "x" => 1,
              "y" => 2
            },
            "departureTime" => "2026-01-01T00:00:00.000Z",
            "arrival" => "2026-01-01T00:00:00.000Z"
          }
        },
        "crew" => %{"current" => 1, "required" => 1, "capacity" => 1, "rotation" => "STRICT"},
        "frame" => %{
          "symbol" => "FRAME_FRIGATE",
          "name" => "Frigate",
          "description" => "A frigate",
          "moduleSlots" => 2,
          "mountingPoints" => 1,
          "fuelCapacity" => 200,
          "condition" => 100,
          "integrity" => 100,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "reactor" => %{
          "symbol" => "REACTOR_SOLAR_I",
          "name" => "Solar I",
          "description" => "A reactor",
          "condition" => 100,
          "integrity" => 100,
          "powerOutput" => 1,
          "requirements" => %{"crew" => 1}
        },
        "engine" => %{
          "symbol" => "ENGINE_IMPULSE_DRIVE_I",
          "name" => "Impulse Drive I",
          "description" => "An engine",
          "condition" => 100,
          "integrity" => 100,
          "speed" => 1,
          "requirements" => %{"power" => 1, "crew" => 1}
        },
        "modules" => [],
        "mounts" => [],
        "fuel" => %{
          "capacity" => 200,
          "current" => 150,
          "consumed" => %{"amount" => 50, "timestamp" => "2026-01-01T00:00:00.000Z"}
        },
        "cargo" => %{
          "capacity" => 40,
          "units" => 12,
          "inventory" => [
            %{"symbol" => "IRON_ORE", "name" => "Iron Ore", "description" => "Ore", "units" => 12}
          ]
        },
        "cooldown" => %{
          "shipSymbol" => symbol,
          "totalSeconds" => 0,
          "remainingSeconds" => 0,
          "expiration" => "2026-01-01T00:00:00.000Z"
        }
      },
      overrides
    )
  end

  describe "list_ships/1" do
    test "pulls the agent's live fleet from the game API" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships"

        Req.Test.json(conn, %{
          "data" => [
            ship_body("ORBITALIST-1"),
            ship_body("ORBITALIST-2", %{
              "registration" => %{
                "name" => "ORBITALIST-2",
                "factionSymbol" => "COSMIC",
                "role" => "SATELLITE"
              },
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "IN_ORBIT",
                "flightMode" => "CRUISE"
              }
            })
          ]
        })
      end)

      agent = %AgentRecord{agent_token: "AGENT_TOKEN"}

      assert {:ok,
              [
                %Model.Ship{symbol: "ORBITALIST-1", nav: %Model.ShipNav{status: "DOCKED"}},
                %Model.Ship{
                  symbol: "ORBITALIST-2",
                  registration: %Model.ShipRegistration{role: "SATELLITE"},
                  nav: %Model.ShipNav{status: "IN_ORBIT"}
                }
              ]} = Fleet.list_ships(agent)
    end

    test "authorizes the request with the agent's token" do
      import Plug.Conn, only: [get_req_header: 2]

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert get_req_header(conn, "authorization") == ["Bearer AGENT_TOKEN"]
        Req.Test.json(conn, %{"data" => []})
      end)

      assert {:ok, []} = Fleet.list_ships(%AgentRecord{agent_token: "AGENT_TOKEN"})
    end

    test "returns an error when the agent has no stored token" do
      assert {:error, :agent_token_missing} = Fleet.list_ships(%AgentRecord{agent_token: nil})
    end

    test "propagates gameplay errors from the API" do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn
        |> Map.put(:status, 401)
        |> Req.Test.json(%{"error" => %{"code" => 4011, "message" => "Invalid token"}})
      end)

      assert {:error, %SpaceTraders.API.GameplayError{}} =
               Fleet.list_ships(%AgentRecord{agent_token: "BAD"})
    end
  end
end
