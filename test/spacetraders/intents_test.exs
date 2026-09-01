defmodule SpaceTraders.IntentsTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.Fleet.Intents

  test "requests a Navigate goal through the shared execution seam" do
    agent = agent_fixture("INTENTS-NAV")
    ship_fixture(agent, "INTENTS-NAV-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {"/v2/my/ships/INTENTS-NAV-SHIP", "GET"} == {conn.request_path, conn.method}

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "INTENTS-NAV-SHIP",
          "nav" => %{
            "systemSymbol" => "X1-UX81",
            "waypointSymbol" => "X1-UX81-A2",
            "route" => %{
              "destination" => %{"symbol" => "X1-UX81-A2"},
              "departure" => %{"symbol" => "X1-UX81-A2"}
            },
            "status" => "IN_ORBIT",
            "flightMode" => "CRUISE"
          },
          "fuel" => %{"current" => 100, "capacity" => 100},
          "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
          "cooldown" => %{"remainingSeconds" => 0}
        }
      })
    end)

    assert {:ok, %Intent{status: "completed", target_waypoint: "X1-UX81-A2"}} =
             Intents.request(
               agent,
               %Intents.ManualControl{},
               "INTENTS-NAV-SHIP",
               %Intents.Navigate{waypoint: " X1-UX81-A2 "}
             )
  end

  test "current and historical reads are scoped to the Agent" do
    first_agent = agent_fixture("INTENTS-ONE")
    second_agent = agent_fixture("INTENTS-TWO")
    first_ship = ship_fixture(first_agent, "INTENTS-SHIP-ONE")
    second_ship = ship_fixture(second_agent, "INTENTS-SHIP-TWO")

    Repo.insert!(%Intent{
      ship_id: first_ship.id,
      target_waypoint: "X1-UX81-A1",
      status: "awaiting_confirmation"
    })

    Repo.insert!(%Intent{
      ship_id: first_ship.id,
      target_waypoint: "X1-UX81-A2",
      status: "completed"
    })

    Repo.insert!(%Intent{
      ship_id: second_ship.id,
      target_waypoint: "X1-UX81-A3",
      status: "active"
    })

    assert [%Intent{status: "awaiting_confirmation"}] = Intents.current(first_agent)
    assert [%Intent{status: "completed"}] = Intents.history(first_agent)
    assert [%Intent{status: "active"}] = Intents.current(second_agent)
  end

  defp agent_fixture(symbol) do
    Repo.insert!(%AgentRecord{
      symbol: symbol,
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN"
    })
  end

  defp ship_fixture(agent, symbol) do
    Repo.insert!(%Ship{symbol: symbol, ship_type: "SHIP_COMMAND_FRIGATE", agent_id: agent.id})
  end
end
