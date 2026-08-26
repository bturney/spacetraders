defmodule SpaceTraders.IntelligenceTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.API.Model.{Market, Waypoint}
  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Intelligence
  alias SpaceTraders.Fleet
  alias SpaceTraders.Repo

  defp agent do
    Repo.insert!(%AgentRecord{
      symbol: "INTEL-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN"
    })
  end

  test "retains usable waypoint facts when a later partial observation omits them" do
    agent = agent()

    complete =
      Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 4,
        "y" => -2,
        "traits" => [%{"symbol" => "MARKETPLACE"}],
        "modifiers" => [
          %{"symbol" => "RADIATION_LEAK", "name" => "Leak", "description" => "Caution"}
        ]
      })

    partial =
      Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET"
      })

    assert {:ok, _} = Intelligence.observe_waypoint(agent, complete, source: "get_waypoint")
    assert {:ok, _} = Intelligence.observe_waypoint(agent, partial, source: "get_waypoints")

    facts = Intelligence.subject(agent, :waypoint, "X1-UX81", "X1-UX81-A1")

    assert %{state: "known", value: [%{"symbol" => "RADIATION_LEAK"}]} = facts["modifiers"]
    assert facts["modifiers"].observation.source == "get_waypoint"
    assert %{state: "known", value: 4} = facts["x"]
    assert facts["x"].observation.source == "get_waypoint"
  end

  test "retains independent market provenance and invalidates only the changed subject" do
    agent = agent()

    market =
      Market.from_json(%{
        "symbol" => "X1-UX81-A1",
        "exports" => [%{"symbol" => "IRON_ORE", "name" => "Iron Ore", "description" => "Ore"}]
      })

    assert {:ok, _} =
             Intelligence.observe_market(agent, "X1-UX81", market,
               source: "get_market",
               observing_ship_symbol: "INTEL-1"
             )

    facts = Intelligence.subject(agent, :market, "X1-UX81", "X1-UX81-A1")
    assert facts["exports"].observation.observing_ship_symbol == "INTEL-1"

    assert {:ok, 6} = Intelligence.invalidate(agent, :market, "X1-UX81", "X1-UX81-A1")
    assert Intelligence.subject(agent, :market, "X1-UX81", "X1-UX81-A1") == %{}
  end

  test "records known-unavailable facts without turning them into negative values" do
    agent = agent()

    assert {:ok, _} =
             Intelligence.mark_unavailable(
               agent,
               "market",
               "X1-UX81",
               "X1-UX81-A2",
               [
                 :exports
               ],
               source: "get_market"
             )

    assert %{state: "known_unavailable", value: nil} =
             Intelligence.subject(agent, :market, "X1-UX81", "X1-UX81-A2")["exports"]
  end

  test "remote market composition does not claim omitted live listings are empty" do
    agent = agent()

    market =
      Market.from_json(%{
        "symbol" => "X1-UX81-A1",
        "exports" => [%{"symbol" => "IRON_ORE", "name" => "Iron Ore", "description" => "Ore"}]
      })

    assert {:ok, _} = Intelligence.observe_market(agent, "X1-UX81", market, source: "get_market")

    facts = Intelligence.subject(agent, :market, "X1-UX81", "X1-UX81-A1")
    assert Map.has_key?(facts, "exports")
    refute Map.has_key?(facts, "trade_goods")
    refute Map.has_key?(facts, "transactions")
  end

  test "Fleet waypoint reads persist subject-first intelligence" do
    agent = agent()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/systems/X1-UX81/waypoints"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "symbol" => "X1-UX81-A1",
            "systemSymbol" => "X1-UX81",
            "type" => "PLANET",
            "x" => 1,
            "y" => 2,
            "traits" => []
          }
        ],
        "meta" => %{"page" => 1, "total" => 1}
      })
    end)

    assert {:ok, [_]} = Fleet.list_waypoints(agent)

    assert %{state: "known", value: "PLANET"} =
             Intelligence.subject(agent, :waypoint, "X1-UX81", "X1-UX81-A1")["type"]
  end
end
