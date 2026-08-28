defmodule SpaceTraders.IntelligenceTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.API.Model.{Construction, JumpGate, Market, Waypoint}
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

  test "keeps authoritative construction material progress as independently usable facts" do
    agent = agent()

    construction =
      Construction.from_json(%{
        "symbol" => "X1-UX81-A1",
        "isComplete" => false,
        "materials" => [
          %{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 7}
        ]
      })

    assert {:ok, _} =
             Intelligence.observe_construction(agent, "X1-UX81", construction,
               source: "get_construction",
               observing_ship_symbol: "INTEL-1"
             )

    facts = Intelligence.subject(agent, :construction, "X1-UX81", "X1-UX81-A1")

    assert %{state: "known", value: false} = facts["complete"]
    assert %{state: "known", value: 20} = facts["material:IRON_ORE:required"]
    assert %{state: "known", value: 7} = facts["material:IRON_ORE:fulfilled"]
    assert %{state: "known", value: 13} = facts["material:IRON_ORE:remaining"]
    assert facts["material:IRON_ORE:remaining"].observation.observing_ship_symbol == "INTEL-1"
  end

  test "records jump-gate connections without claiming either endpoint is complete" do
    agent = agent()
    gate = JumpGate.from_json(%{"symbol" => "X1-UX81-A1", "connections" => ["X1-TEST-A1"]})

    assert {:ok, _} =
             Intelligence.observe_jump_gate(agent, "X1-UX81", gate,
               source: "get_jump_gate",
               observing_ship_symbol: "INTEL-1"
             )

    facts = Intelligence.subject(agent, :jump_gate, "X1-UX81", "X1-UX81-A1")

    assert %{state: "known", value: ["X1-TEST-A1"]} = facts["connections"]
    refute Map.has_key?(facts, "complete")
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

  test "Fleet construction and jump-gate reads expose independent public intelligence" do
    agent = agent()

    construction_waypoint =
      Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "JUMP_GATE"
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => false,
              "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 7}]
            }
          })

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/jump-gate" ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => "X1-UX81-A1", "connections" => ["X1-TEST-A1"]}
          })
      end
    end)

    assert {:ok, _} = Fleet.waypoint_construction(agent, construction_waypoint)
    assert {:ok, _} = Fleet.waypoint_jump_gate(agent, construction_waypoint)

    assert %{value: 13} =
             Intelligence.subject(agent, :construction, "X1-UX81", "X1-UX81-A1")[
               "material:IRON_ORE:remaining"
             ]

    assert %{value: ["X1-TEST-A1"]} =
             Intelligence.subject(agent, :jump_gate, "X1-UX81", "X1-UX81-A1")["connections"]
  end

  test "Fleet supply precondition failures invalidate stale construction facts" do
    agent = agent()

    construction =
      Construction.from_json(%{
        "symbol" => "X1-UX81-A1",
        "isComplete" => false,
        "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 7}]
      })

    assert {:ok, _} =
             Intelligence.observe_construction(agent, "X1-UX81", construction,
               source: "get_construction"
             )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Map.put(:status, 400)
      |> Req.Test.json(%{"error" => %{"code" => 4218, "message" => "Insufficient cargo"}})
    end)

    assert {:error, %SpaceTraders.API.GameplayError{type: :insufficient_cargo}} =
             Fleet.supply_construction(agent, "X1-UX81", "X1-UX81-A1", "INTEL-1", "IRON_ORE", 5)

    assert Intelligence.subject(agent, :construction, "X1-UX81", "X1-UX81-A1") == %{}
  end

  test "reports exact baseline gaps for every listed Waypoint" do
    agent = agent()

    complete =
      Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 4,
        "y" => -2,
        "orbits" => "X1-UX81-A0",
        "orbitals" => [],
        "traits" => [],
        "modifiers" => [],
        "chart" => %{"submittedBy" => "INTEL", "submittedOn" => "2026-01-01T00:00:00Z"},
        "isUnderConstruction" => false
      })

    incomplete =
      Waypoint.from_json(%{
        "symbol" => "X1-UX81-A2",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 5,
        "y" => -2,
        "traits" => []
      })

    market = Market.from_json(%{"symbol" => "X1-UX81-A1", "exports" => []})

    assert {:ok, _} = Intelligence.observe_waypoint(agent, complete, source: "get_waypoint")
    assert {:ok, _} = Intelligence.observe_waypoint(agent, incomplete, source: "get_waypoints")
    assert {:ok, _} = Intelligence.observe_market(agent, "X1-UX81", market, source: "get_market")

    assert %{
             "X1-UX81-A1" => %{missing: []},
             "X1-UX81-A2" => %{missing: missing}
           } = Intelligence.waypoint_coverage(agent, "X1-UX81", [complete, incomplete])

    assert "modifiers" in missing
    assert "is_under_construction" in missing
    refute "chart" in missing
  end
end
