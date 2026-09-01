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

  test "reviews and blocks Manual Control Navigate through the seam" do
    agent = agent_fixture("INTENTS-REVIEW")
    ship_fixture(agent, "INTENTS-REVIEW-SHIP")

    assert {:ok, %Intent{status: "awaiting_confirmation", review_revision: 1}} =
             Intents.review(
               agent,
               %Intents.ManualControl{},
               "INTENTS-REVIEW-SHIP",
               "X1-UX81-A2",
               %{method: "jump", source_waypoint: "X1-UX81-A1"}
             )

    assert {:ok, %Intent{status: "blocked"}} =
             Intents.block_review(
               agent,
               %Intents.ManualControl{},
               "INTENTS-REVIEW-SHIP",
               "X1-UX81-A3",
               {:jump_route_candidates, :unavailable, []}
             )
  end

  test "stops the exact owned Manual Control Intent" do
    agent = agent_fixture("INTENTS-STOP")
    ship = ship_fixture(agent, "INTENTS-STOP-SHIP")

    intent = Repo.insert!(%Intent{ship_id: ship.id, target_waypoint: "X1-UX81-A2"})

    assert :ok = Intents.stop(agent, %Intents.ManualControl{}, intent.id)
    assert %Intent{status: "stopped"} = Repo.get!(Intent, intent.id)
  end

  test "binds stopping to the requested Ship" do
    agent = agent_fixture("INTENTS-MISMATCH")
    ship = ship_fixture(agent, "INTENTS-SHIP-ONE")
    ship_fixture(agent, "INTENTS-SHIP-TWO")
    intent = Repo.insert!(%Intent{ship_id: ship.id, target_waypoint: "X1-UX81-A2"})

    assert {:error, :intent_ship_mismatch} =
             Intents.stop(agent, %Intents.ManualControl{}, "INTENTS-SHIP-TWO", intent.id)

    assert %Intent{status: "active"} = Repo.get!(Intent, intent.id)
  end

  test "refuses to stop Navigate with unresolved mutation evidence" do
    agent = agent_fixture("INTENTS-EVIDENCE")
    ship = ship_fixture(agent, "INTENTS-EVIDENCE-SHIP")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate"}
      })

    assert {:error, :intents_reconciliation_required} =
             Intents.stop(agent, %Intents.ManualControl{}, intent.id)

    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)
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
