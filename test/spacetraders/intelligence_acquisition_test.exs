defmodule SpaceTraders.IntelligenceAcquisitionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Evidence
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetAllocation.Reconciler
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.World

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  test "a claimed root Intent acquires publicly available Waypoint facts without moving the Ship" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case conn.request_path do
        ^ship_path ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A2" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "x" => 2,
              "y" => 4,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "completed", type: "acquire_intelligence"}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A2",
               required_facts: ["type", "traits"],
               freshness_seconds: 300
             })

    assert_receive {"GET", ^ship_path}
    assert_receive {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"}
    refute_receive {"POST", _}

    projection =
      World.intelligence(agent, :waypoint, "X1-UX81", "X1-UX81-A2", DateTime.utc_now(), 300)

    assert projection.known_existence?
    assert projection.facts["traits"].source == "Public Waypoint observation"
    assert projection.facts["traits"].freshness == :fresh
  end

  test "without a current matching Claim acquisition refuses before any game traffic" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, portfolio.fleet_generation_id)

    Req.Test.stub(SpaceTraders.API, fn _conn -> flunk("unclaimed Ship cannot observe") end)

    assert {:error, :no_current_ship_claim} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A2",
               required_facts: ["traits"],
               freshness_seconds: 300
             })

    assert Intents.current(agent) == []
  end

  test "an on-site Market Listing is retained only after the claimed Ship reaches the Market" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case conn.request_path do
        ^ship_path ->
          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("DOCKED")})
          })

        "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [%{"symbol" => "IRON_ORE"}],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "tradeVolume" => 10,
                  "purchasePrice" => 20,
                  "sellPrice" => 18
                }
              ]
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "completed"}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert_receive {"GET", ^ship_path}
    assert_receive {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"}
    refute_receive {"POST", _}

    projection =
      World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

    assert [%{"symbol" => "IRON_ORE"}] = projection.facts["trade_goods"].value
    assert projection.facts["trade_goods"].observing_ship_symbol == ship.symbol
  end

  test "Market acquisition navigates within its claimed root Intent and waits for arrival" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = "#{ship_path}/orbit"
    navigate_path = "#{ship_path}/navigate"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/market"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" =>
                nav_body("IN_TRANSIT",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  destination: "X1-UX81-A2"
                )
            }
          })

        {"GET", ^waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "x" => 2,
              "y" => 2,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "exports" => [],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => []
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "waiting"} = intent} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A2",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
    refute_receive {"GET", ^market_path}

    arrived =
      ship_body(ship.symbol, %{
        "nav" => nav_body("DOCKED", destination: "X1-UX81-A2")
      })
      |> Model.Ship.from_json()

    assert :ok = Intents.reconcile(agent.id, ship.symbol, arrived, :arrival, intent.id)
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)
    assert_receive {"GET", ^market_path}
  end

  test "an insufficient-fuel navigation at a confirmed fuel Market refuels before dispatch" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    {:ok, fuel_state} = Elixir.Agent.start_link(fn -> :low end)
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    navigate_path = "#{ship_path}/navigate"
    dock_path = "#{ship_path}/dock"
    orbit_path = "#{ship_path}/orbit"
    refuel_path = "#{ship_path}/refuel"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Process.put(:fuel_test_navigate_calls, 0)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          {nav, fuel} =
            if Elixir.Agent.get(fuel_state, & &1) == :low do
              {nav_body("IN_ORBIT"),
               %{
                 "capacity" => 200,
                 "current" => 55,
                 "consumed" => %{
                   "amount" => 145,
                   "timestamp" => "2026-01-01T00:00:00.000Z"
                 }
               }}
            else
              {nav_body("DOCKED"), %{"capacity" => 200, "current" => 200}}
            end

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav, "fuel" => fuel})
          })

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "FUEL",
                  "type" => "EXCHANGE",
                  "tradeVolume" => 10,
                  "purchasePrice" => 72,
                  "sellPrice" => 68,
                  "supply" => "MODERATE"
                }
              ]
            }
          })

        {"GET", ^waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "x" => 68,
              "y" => 2,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        {"POST", ^navigate_path} ->
          count = Process.get(:fuel_test_navigate_calls, 0)
          Process.put(:fuel_test_navigate_calls, count + 1)

          assert count == 0

          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 133},
              "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
            }
          })

        {"POST", ^dock_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})

        {"POST", ^refuel_path} ->
          Elixir.Agent.update(fuel_state, fn _ -> :full end)

          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{
                "symbol" => agent.symbol,
                "credits" => 100_000,
                "headquarters" => "X1-UX81-A1",
                "shipCount" => 1,
                "startingFaction" => "COSMIC"
              },
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "fuel" => %{"capacity" => 200, "current" => 200},
              "transaction" => %{
                "shipSymbol" => ship.symbol,
                "waypointSymbol" => "X1-UX81-A1",
                "tradeSymbol" => "FUEL",
                "type" => "PURCHASE",
                "units" => 145,
                "pricePerUnit" => 72,
                "totalPrice" => 10_440,
                "timestamp" => "2026-01-01T00:00:00.000Z"
              }
            }
          })

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "waiting"} = intent} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A2",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert_receive {"GET", ^ship_path}
    assert_receive {"GET", ^waypoint_path}
    assert_receive {"POST", ^dock_path}
    assert_receive {"GET", ^market_path}
    assert_receive {"POST", ^refuel_path}
    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
    assert Process.get(:fuel_test_navigate_calls) == 1
    assert %Intent{parameters: %{"refuel" => "to_capacity"}} = Repo.get!(Intent, intent.id)
  end

  test "a fuel-independent Ship navigates without refueling" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = "#{ship_path}/orbit"
    navigate_path = "#{ship_path}/navigate"
    dock_path = "#{ship_path}/dock"
    refuel_path = "#{ship_path}/refuel"
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("DOCKED"),
                "fuel" => %{"capacity" => 0, "current" => 0}
              })
          })

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 0, "current" => 0},
              "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
            }
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "waiting"}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A2",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
    refute_receive {"POST", ^dock_path}
    refute_receive {"POST", ^refuel_path}
  end

  test "a leg beyond tank capacity selects a reachable confirmed fuel stop" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = "#{ship_path}/orbit"
    navigate_path = "#{ship_path}/navigate"
    target_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A3"

    observe_fuel_stop(agent, ship.symbol, "X1-UX81-A2", 51, 2)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path, conn.body_params})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("DOCKED"),
                "fuel" => %{"capacity" => 60, "current" => 60}
              })
          })

        {"GET", ^target_path} ->
          Req.Test.json(conn, %{
            "data" => waypoint_body("X1-UX81-A3", "X1-UX81", "PLANET", 101, 2)
          })

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 60, "current" => 10},
              "nav" =>
                nav_body("IN_TRANSIT",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  destination: "X1-UX81-A2"
                )
            }
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "waiting", in_flight_action: action}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A3",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert action["kind"] == "navigate"
    assert action["waypoint"] == "X1-UX81-A2"
    assert_receive {"POST", ^navigate_path, %{"waypointSymbol" => "X1-UX81-A2"}}
  end

  test "a full tank does not dispatch a leg with no confirmed reachable fuel stop" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    target_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A3"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "fuel" => %{"capacity" => 50, "current" => 50}
              })
          })

        {"GET", ^target_path} ->
          Req.Test.json(conn, %{
            "data" => waypoint_body("X1-UX81-A3", "X1-UX81", "PLANET", 101, 2)
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "infeasible", last_action_result: result}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X1-UX81-A3",
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert get_in(result, ["evidence", "reason"]) == "no_confirmed_reachable_refuel_stop"
    refute_receive {"POST", _path}
  end

  test "navigation fuel estimates apply flight-mode formulas, rounding, and minimums" do
    estimates = fn x1, y1, x2, y2, mode ->
      {:ok, value} =
        Intents.navigation_fuel_estimate(%{x: x1, y: y1}, %{x: x2, y: y2}, mode)

      value
    end

    assert estimates.(1, 2, 68, 2, "CRUISE") == 67
    assert estimates.(1, 2, 68, 2, "STEALTH") == 67
    assert estimates.(1, 2, 68, 2, "BURN") == 134
    assert estimates.(0, 0, 1, 1, "DRIFT") == 1
    assert estimates.(0, 0, 1, 1, "CRUISE") == 1
    assert estimates.(0, 0, 1, 1, "BURN") == 2
    assert estimates.(0, 0, 4, 5, "CRUISE") == 6

    assert {:error, :flight_mode_unavailable} =
             Intents.navigation_fuel_estimate(%{x: 1, y: 2}, %{x: 3, y: 4}, "UNKNOWN")

    assert {:error, :navigation_coordinates_unavailable} =
             Intents.navigation_fuel_estimate(%{x: 1, y: 2}, %{x: nil, y: 4}, "CRUISE")
  end

  test "a destination-only Fleet Commitment selects warp from authoritative Ship capability" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    {:ok, warp_state} = Elixir.Agent.start_link(fn -> :ready end)
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    warp_path = "#{ship_path}/warp"
    target_waypoint_path = "/v2/systems/X2-UX81/waypoints/X2-UX81-A3"
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    warp_drive = %{
      "symbol" => "MODULE_WARP_DRIVE_I",
      "name" => "Warp Drive I",
      "description" => "Inter-system drive",
      "range" => 10,
      "requirements" => %{"power" => 1, "crew" => 0, "slots" => 1}
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path, conn.body_params})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          nav =
            if Elixir.Agent.get(warp_state, & &1) == :ready do
              nav_body("IN_ORBIT")
            else
              nav_body("IN_TRANSIT", arrival: arrival, destination: "X2-UX81-A3")
              |> Map.put("systemSymbol", "X2-UX81")
            end

          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav, "modules" => [warp_drive]})
          })

        {"POST", ^warp_path} ->
          Elixir.Agent.update(warp_state, fn _ -> :in_transit end)

          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" => %{
                "systemSymbol" => "X2-UX81",
                "waypointSymbol" => "X2-UX81-A3",
                "status" => "IN_TRANSIT",
                "flightMode" => "CRUISE",
                "route" => %{
                  "destination" => %{
                    "symbol" => "X2-UX81-A3",
                    "systemSymbol" => "X2-UX81",
                    "type" => "PLANET",
                    "x" => 4,
                    "y" => 5
                  },
                  "origin" => %{
                    "symbol" => "X1-UX81-A1",
                    "systemSymbol" => "X1-UX81",
                    "type" => "PLANET",
                    "x" => 1,
                    "y" => 2
                  },
                  "departureTime" => "2026-01-01T00:00:00.000Z",
                  "arrival" => arrival
                }
              }
            }
          })

        {"GET", ^target_waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X2-UX81-A3",
              "systemSymbol" => "X2-UX81",
              "type" => "PLANET",
              "x" => 4,
              "y" => 5,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "waiting", in_flight_action: action} = intent} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: "X2-UX81-A3",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               constraints: %{allowed_methods: ["warp"]}
             })

    assert action["kind"] == "warp"

    assert intent.parameters == %{
             "system" => "X2-UX81",
             "subject_type" => "market",
             "required_facts" => ["trade_goods"],
             "freshness_seconds" => 300,
             "allowed_methods" => ["warp"]
           }

    assert_receive {"POST", ^warp_path, %{"waypointSymbol" => "X2-UX81-A3"}}

    ShipServer.stop(ship.symbol)
    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)
    refute_receive {"POST", ^warp_path, _body}
  end

  test "a destination-only Fleet Commitment selects gates then continues to the remote Waypoint" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    {:ok, route_state} = Elixir.Agent.start_link(fn -> :source_gate end)
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    jump_path = "#{ship_path}/jump"
    navigate_path = "#{ship_path}/navigate"
    source_gate = "X1-UX81-GATE"
    destination_gate = "X2-UX81-GATE"
    target = "X2-UX81-A3"
    source_jump_gate_path = "/v2/systems/X1-UX81/waypoints/#{source_gate}/jump-gate"
    destination_jump_gate_path = "/v2/systems/X2-UX81/waypoints/#{destination_gate}/jump-gate"
    source_construction_path = "/v2/systems/X1-UX81/waypoints/#{source_gate}/construction"

    destination_construction_path =
      "/v2/systems/X2-UX81/waypoints/#{destination_gate}/construction"

    source_market_path = "/v2/systems/X1-UX81/waypoints/#{source_gate}/market"
    target_waypoint_path = "/v2/systems/X2-UX81/waypoints/#{target}"
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path, conn.body_params})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          waypoint =
            if Elixir.Agent.get(route_state, & &1) == :source_gate,
              do: source_gate,
              else: destination_gate

          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" =>
                  nav_body("IN_ORBIT", destination: waypoint)
                  |> Map.put(
                    "systemSymbol",
                    if(waypoint == source_gate, do: "X1-UX81", else: "X2-UX81")
                  ),
                "fuel" => %{"capacity" => 200, "current" => 200},
                "cooldown" => %{
                  "shipSymbol" => ship.symbol,
                  "totalSeconds" => 0,
                  "remainingSeconds" => 0,
                  "expiration" => "2026-01-01T00:00:00.000Z"
                }
              })
          })

        {"GET", "/v2/systems/X1-UX81/waypoints"} ->
          Req.Test.json(conn, %{
            "data" => [waypoint_body(source_gate, "X1-UX81", "JUMP_GATE")],
            "meta" => %{"page" => 1, "total" => 1, "limit" => 20}
          })

        {"GET", ^source_jump_gate_path} ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => source_gate, "connections" => [destination_gate]}
          })

        {"GET", ^destination_jump_gate_path} ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => destination_gate, "connections" => [source_gate]}
          })

        {"GET", ^source_construction_path} ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => source_gate, "isComplete" => true, "materials" => []}
          })

        {"GET", ^destination_construction_path} ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => destination_gate, "isComplete" => true, "materials" => []}
          })

        {"GET", ^target_waypoint_path} ->
          Req.Test.json(conn, %{"data" => waypoint_body(target, "X2-UX81", "PLANET")})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 100_000,
              "headquarters" => "X1-UX81-A1",
              "shipCount" => 1,
              "startingFaction" => "COSMIC"
            }
          })

        {"GET", ^source_market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => source_gate,
              "exports" => [],
              "imports" => [],
              "exchange" => [%{"symbol" => "ANTIMATTER"}],
              "tradeGoods" => [
                %{
                  "symbol" => "ANTIMATTER",
                  "type" => "EXCHANGE",
                  "tradeVolume" => 10,
                  "purchasePrice" => 1_000,
                  "sellPrice" => 900
                }
              ]
            }
          })

        {"POST", ^jump_path} ->
          Elixir.Agent.update(route_state, fn _ -> :destination_gate end)

          Req.Test.json(conn, %{
            "data" => %{
              "nav" =>
                nav_body("IN_ORBIT", destination: destination_gate)
                |> Map.put("systemSymbol", "X2-UX81"),
              "cooldown" => %{"shipSymbol" => ship.symbol, "remainingSeconds" => 0},
              "transaction" => %{"waypointSymbol" => source_gate, "pricePerUnit" => 1_000},
              "agent" => %{"symbol" => agent.symbol, "credits" => 99_000}
            }
          })

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 190},
              "nav" =>
                nav_body("IN_TRANSIT", arrival: arrival, destination: target)
                |> Map.put("systemSymbol", "X2-UX81")
            }
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "waiting", in_flight_action: action}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :market,
               waypoint: target,
               required_facts: ["trade_goods"],
               freshness_seconds: 300
             })

    assert action["kind"] == "navigate"
    assert action["waypoint"] == target
    assert_receive {"POST", ^jump_path, %{"waypointSymbol" => ^destination_gate}}
    assert_receive {"POST", ^navigate_path, %{"waypointSymbol" => ^target}}
  end

  test "a claimed Ship charts on-site after public intelligence cannot establish chart provenance" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"
    orbit_path = "#{ship_path}/orbit"
    chart_path = "#{ship_path}/chart"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", ^waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "traits" => []
            }
          })

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^chart_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "chart" => %{
                "waypointSymbol" => "X1-UX81-A1",
                "submittedBy" => agent.symbol,
                "submittedOn" => DateTime.utc_now() |> DateTime.to_iso8601()
              },
              "waypoint" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "traits" => [],
                "chart" => %{
                  "submittedBy" => agent.symbol,
                  "submittedOn" => DateTime.utc_now() |> DateTime.to_iso8601()
                }
              },
              "agent" => %{"symbol" => agent.symbol, "credits" => 1000}
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "completed"}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A1",
               required_facts: ["chart"],
               freshness_seconds: 300
             })

    assert_receive {"GET", ^waypoint_path}
    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^chart_path}

    projection =
      World.intelligence(agent, :waypoint, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

    assert projection.facts["chart"].value["submitted_by"] == agent.symbol
    assert projection.facts["chart"].source == "Chart"
  end

  test "a sensor-equipped claimed Ship scans only after public Waypoint observation is unavailable" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"
    scan_path = "#{ship_path}/scan/waypoints"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "mounts" => [%{"symbol" => "MOUNT_SENSOR_ARRAY_I", "name" => "Sensor Array"}]
              })
          })

        {"GET", ^waypoint_path} ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Not visible"}})

        {"POST", ^scan_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "cooldown" => %{
                "shipSymbol" => ship.symbol,
                "totalSeconds" => 60,
                "remainingSeconds" => 60,
                "expiration" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
              },
              "waypoints" => [
                %{
                  "symbol" => "X1-UX81-A2",
                  "systemSymbol" => "X1-UX81",
                  "type" => "PLANET",
                  "x" => 5,
                  "y" => 6,
                  "traits" => [%{"symbol" => "MARKETPLACE"}],
                  "orbitals" => []
                }
              ]
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "completed"}} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A2",
               required_facts: ["traits"],
               freshness_seconds: 300
             })

    assert_receive {"GET", ^waypoint_path}
    assert_receive {"POST", ^scan_path}

    projection =
      World.intelligence(agent, :waypoint, "X1-UX81", "X1-UX81-A2", DateTime.utc_now(), 300)

    assert projection.facts["traits"].source == "Ship scan"
    assert projection.facts["modifiers"] == nil
  end

  test "a lost chart response reconciles the chart instead of replaying the mutation" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"
    chart_path = "#{ship_path}/chart"
    {:ok, phase} = Elixir.Agent.start_link(fn -> :before end)
    {:ok, charts} = Elixir.Agent.start_link(fn -> 0 end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})
          })

        {"GET", ^waypoint_path} ->
          chart =
            if Elixir.Agent.get(phase, & &1) == :after,
              do: %{
                "waypointSymbol" => "X1-UX81-A1",
                "submittedBy" => agent.symbol,
                "submittedOn" => DateTime.utc_now() |> DateTime.to_iso8601()
              }

          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "traits" => [],
              "chart" => chart
            }
          })

        {"POST", ^chart_path} ->
          Elixir.Agent.update(charts, &(&1 + 1))
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:ok, %Intent{status: "blocked", in_flight_action: %{"kind" => "chart"}} = intent} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A1",
               required_facts: ["chart"],
               freshness_seconds: 300
             })

    Elixir.Agent.update(phase, fn _ -> :after end)

    live_ship =
      ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")}) |> Model.Ship.from_json()

    assert :ok = Intents.reconcile(agent.id, ship.symbol, live_ship, :boot, intent.id)
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)
    assert Elixir.Agent.get(charts, & &1) == 1
  end

  test "a fresh credit-growth Fleet acquires one Market Listing through a claimed root Intent" do
    {agent, ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))
    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    for {symbol, x, y, traits} <- [
          {"X1-UX81-A1", 1, 2, []},
          {"X1-UX81-A2", 2, 4, [%{"symbol" => "MARKETPLACE"}]},
          {"X1-UX81-A3", 4, 4, [%{"symbol" => "MARKETPLACE"}]}
        ] do
      waypoint =
        Model.Waypoint.from_json(%{
          "symbol" => symbol,
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => x,
          "y" => y,
          "traits" => traits
        })

      {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
    end

    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = "#{ship_path}/orbit"
    navigate_path = "#{ship_path}/navigate"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2/market"
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" =>
                nav_body("IN_TRANSIT",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  destination: "X1-UX81-A2"
                )
            }
          })

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "tradeVolume" => 20,
                  "purchasePrice" => 10,
                  "sellPrice" => 9
                }
              ]
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, %{intent: %Intent{status: "waiting", target_waypoint: "X1-UX81-A2"} = intent}} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })

    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
    refute_receive {"GET", ^market_path}

    arrived =
      ship_body(ship.symbol, %{
        "nav" => nav_body("DOCKED", destination: "X1-UX81-A2")
      })
      |> Model.Ship.from_json()

    assert :ok = Intents.reconcile(agent.id, ship.symbol, arrived, :arrival, intent.id)
    assert_receive {"GET", ^market_path}
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)

    assert [%{subject: "market:X1-UX81:X1-UX81-A2", required_facts: ["trade_goods"]} = demand] =
             Repo.all(
               from demand in SpaceTraders.Evidence.ObservationDemand,
                 where:
                   demand.agent_id == ^agent.id and
                     demand.subject == "market:X1-UX81:X1-UX81-A2" and
                     is_nil(demand.withdrawn_at)
             )

    assert demand.fulfilled_observation_id

    projection =
      World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A2", DateTime.utc_now(), 300)

    assert projection.facts["trade_goods"].freshness == :fresh
    assert projection.facts["trade_goods"].observing_ship_symbol == ship.symbol
    assert projection.facts["trade_goods"].source == "Market observation"
    assert projection.facts["transactions"].state == "unknown"
    assert projection.facts["transactions"].value == nil
  end

  test "Fleet allocation admits a valuable observation and publishes its Ship Claim before acquisition" do
    {agent, ship, old_portfolio, _commitment} = claimed_ship()
    operator = Repo.get!(Operator, agent.operator_id)
    scope = Scope.for_operator(operator)
    revision = Repo.get!(Revision, old_portfolio.fleet_strategy_revision_id)
    ship_path = "/v2/my/ships/#{ship.symbol}"

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, old_portfolio.fleet_generation_id)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, planning} =
             FleetPlanning.plan_intelligence(revision, 0, %{
               as_of: DateTime.utc_now(),
               system_symbol: "X1-UX81",
               agent_id: agent.id,
               opportunities: [
                 %{
                   subject: "waypoint:X1-UX81:X1-UX81-A2",
                   required_facts: ["traits"],
                   facts: %{},
                   expected_decision_value: 100,
                   api_capacity_cost: 5,
                   ship_time_cost: 10,
                   acquisition: :on_site
                 }
               ]
             })

    assert {:ok, %{intent: %Intent{status: "completed"}, commitment: commitment}} =
             FleetExecution.activate_intelligence(scope, agent, revision, planning, %{
               available_slots: 3,
               backpressure: :none
             })

    assert commitment.claims == [ship.symbol]

    assert {:ok, %{commitment_id: commitment_id}} =
             FleetAllocation.current_ship_claim(agent, ship.symbol)

    assert commitment_id == commitment.id
  end

  test "chart objective autonomously selects an on-site uncharted Waypoint from retained evidence" do
    {agent, ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Chart useful waypoints",
        "kind" => "attain",
        "evaluation" => "Increase newly charted waypoint coverage"
      })

    operator = Repo.get!(Operator, agent.operator_id)
    scope = Scope.for_operator(operator)
    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    ship_path = "/v2/my/ships/#{ship.symbol}"
    chart_path = "#{ship_path}/chart"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/systems/X1-UX81/waypoints"} ->
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

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "mounts" => [%{"symbol" => "MOUNT_SENSOR_ARRAY_I", "name" => "Sensor"}]
              })
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" => ship_body(ship.symbol, %{"nav" => nav_body("IN_ORBIT")})
          })

        {"GET", ^waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "traits" => []
            }
          })

        {"POST", ^chart_path} ->
          chart = %{
            "waypointSymbol" => "X1-UX81-A1",
            "submittedBy" => agent.symbol,
            "submittedOn" => DateTime.utc_now() |> DateTime.to_iso8601()
          }

          Req.Test.json(conn, %{
            "data" => %{
              "chart" => chart,
              "waypoint" => %{
                "symbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "traits" => [],
                "chart" => chart
              },
              "agent" => %{"symbol" => agent.symbol, "credits" => 10_100}
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, %{intent: %Intent{status: "completed"}}} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })

    assert {:error, :no_decision_relevant_intelligence} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })
  end

  test "a lost scan response waits for its cooldown and never blindly scans again" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"
    scan_path = "#{ship_path}/scan/waypoints"
    {:ok, calls} = Elixir.Agent.start_link(fn -> %{scan: 0, attempted: false} end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      state = Elixir.Agent.get(calls, & &1)

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          cooldown =
            if state.attempted,
              do: %{
                "shipSymbol" => ship.symbol,
                "totalSeconds" => 60,
                "remainingSeconds" => 60,
                "expiration" => DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
              },
              else: %{
                "shipSymbol" => ship.symbol,
                "totalSeconds" => 0,
                "remainingSeconds" => 0
              }

          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "mounts" => [%{"symbol" => "MOUNT_SENSOR_ARRAY_I", "name" => "Sensor"}],
                "cooldown" => cooldown
              })
          })

        {"GET", ^waypoint_path} ->
          conn
          |> Plug.Conn.put_status(404)
          |> Req.Test.json(%{"error" => %{"code" => 404, "message" => "Not visible"}})

        {"POST", ^scan_path} ->
          Elixir.Agent.update(calls, &%{&1 | scan: &1.scan + 1, attempted: true})
          Req.Test.transport_error(conn, :timeout)
      end
    end)

    assert {:ok,
            %Intent{status: "blocked", in_flight_action: %{"kind" => "scan_waypoints"}} = intent} =
             Intents.request_commitment_intelligence(agent, commitment, portfolio, ship.symbol, %{
               subject_type: :waypoint,
               waypoint: "X1-UX81-A2",
               required_facts: ["traits"],
               freshness_seconds: 300
             })

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    assert %Intent{status: "waiting", parameters: %{"scan_attempted" => true}} =
             Repo.get!(Intent, intent.id)

    assert Elixir.Agent.get(calls, & &1.scan) == 1
  end

  test "credit-growth planning reacquires an on-site stale Listing only when its prior route can matter" do
    {agent, ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    operator = Repo.get!(Operator, agent.operator_id)
    scope = Scope.for_operator(operator)
    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    for {symbol, x, observed_at, buy, sell} <- [
          {"X1-UX81-A1", 1, DateTime.add(DateTime.utc_now(), -600), 10, 9},
          {"X1-UX81-A2", 2, DateTime.utc_now(), 25, 20}
        ] do
      waypoint =
        Model.Waypoint.from_json(%{
          "symbol" => symbol,
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => x,
          "y" => 2,
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        })

      listing =
        Model.Market.from_json(%{
          "symbol" => symbol,
          "exports" => [%{"symbol" => "IRON_ORE"}],
          "imports" => [],
          "exchange" => [],
          "tradeGoods" => [
            %{
              "symbol" => "IRON_ORE",
              "type" => "EXPORT",
              "tradeVolume" => 20,
              "purchasePrice" => buy,
              "sellPrice" => sell
            }
          ]
        })

      {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

      {:ok, _} =
        Intelligence.observe_market(agent, "X1-UX81", listing,
          source: "get_market",
          observing_ship_symbol: ship.symbol,
          observed_at: observed_at
        )
    end

    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [%{"symbol" => "IRON_ORE"}],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "tradeVolume" => 20,
                  "purchasePrice" => 12,
                  "sellPrice" => 9
                }
              ]
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, %{intent: %Intent{status: "completed"}}} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })

    projection =
      World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

    assert projection.facts["trade_goods"].freshness == :fresh
  end

  test "a due Observation Demand wakes Market reconciliation without a recurring scan" do
    {agent, ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    operator = Repo.get!(Operator, agent.operator_id)
    scope = Scope.for_operator(operator)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    # Both Markets are observed, but every Listing has aged past its freshness
    # budget. A durable due Observation Demand is what wakes planning: the
    # fixed recurring Market scan is no longer required for progress.
    for {symbol, x, buy, sell} <- [{"X1-UX81-A1", 1, 10, 9}, {"X1-UX81-A2", 2, 25, 20}] do
      waypoint =
        Model.Waypoint.from_json(%{
          "symbol" => symbol,
          "systemSymbol" => "X1-UX81",
          "type" => "PLANET",
          "x" => x,
          "y" => 2,
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        })

      listing =
        Model.Market.from_json(%{
          "symbol" => symbol,
          "exports" => [%{"symbol" => "IRON_ORE"}],
          "imports" => [],
          "exchange" => [],
          "tradeGoods" => [
            %{
              "symbol" => "IRON_ORE",
              "type" => "EXPORT",
              "tradeVolume" => 20,
              "purchasePrice" => buy,
              "sellPrice" => sell
            }
          ]
        })

      {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

      {:ok, _} =
        Intelligence.observe_market(agent, "X1-UX81", listing,
          source: "get_market",
          observing_ship_symbol: ship.symbol,
          observed_at: DateTime.add(DateTime.utc_now(), -600, :second)
        )
    end

    ship_path = "/v2/my/ships/#{ship.symbol}"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", ^market_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "exports" => [%{"symbol" => "IRON_ORE"}],
              "imports" => [],
              "exchange" => [],
              "tradeGoods" => [
                %{
                  "symbol" => "IRON_ORE",
                  "type" => "EXPORT",
                  "tradeVolume" => 20,
                  "purchasePrice" => 12,
                  "sellPrice" => 9
                }
              ]
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: DateTime.add(DateTime.utc_now(), -1, :second),
               owner: "fleet_planning"
             })

    # The durable scheduler announces due Observation Demands; Strategy
    # reconciliation wakes from that announcement without any recurring scan.
    assert :ok =
             Reconciler.wake_due_demands(agent.id, %{
               available_slots: 3,
               backpressure: :none
             })

    eventually(fn ->
      projection =
        World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

      projection.facts["trade_goods"].freshness == :fresh
    end)

    # The due demand is never deleted: governed evidence fulfils it, and its
    # row keeps the durable attribution either way.
    reloaded = Repo.reload!(demand)

    if is_nil(reloaded.fulfilled_observation_id) and is_nil(reloaded.withdrawn_at) do
      assert length(Evidence.list_open_demands(agent)) >= 1
    end
  end

  test "API backpressure defers a due Observation Demand without deleting or fulfilling it" do
    {agent, _ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))
    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    listing =
      Model.Market.from_json(%{
        "symbol" => "X1-UX81-A1",
        "exports" => [%{"symbol" => "IRON_ORE"}],
        "imports" => [],
        "exchange" => [],
        "tradeGoods" => [
          %{
            "symbol" => "IRON_ORE",
            "type" => "EXPORT",
            "tradeVolume" => 20,
            "purchasePrice" => 12,
            "sellPrice" => 9
          }
        ]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

    {:ok, _} =
      Intelligence.observe_market(agent, "X1-UX81", listing,
        source: "get_market",
        observing_ship_symbol: "INTELACQ-1",
        observed_at: DateTime.add(DateTime.utc_now(), -600, :second)
      )

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: DateTime.add(DateTime.utc_now(), -1, :second),
               owner: "fleet_planning"
             })

    # The governor's published snapshot carries sustained API pressure; the
    # wakeup runs but admission is refused.
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{"symbol" => agent.symbol, "credits" => 10_000}
          })

        _ ->
          conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => %{"code" => 404}})
      end
    end)

    assert :ok =
             Reconciler.wake_due_demands(agent.id, %{
               available_slots: 0,
               backpressure: :sustained
             })

    # The wakeup ran, but sustained API pressure refuses admission: no fresh
    # evidence is acquired and the demand is neither deleted nor fulfilled.
    Process.sleep(100)

    projection =
      World.intelligence(agent, :market, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

    assert projection.facts["trade_goods"].freshness == :stale

    assert %{withdrawn_at: nil, fulfilled_observation_id: nil} = Repo.reload!(demand)
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  test "Fleet growth objective acquires on-site Shipyard offers through a claimed Intent" do
    {agent, ship, previous, _commitment} =
      claimed_ship(%{
        "objective" => "Expand Fleet with a Ship",
        "kind" => "attain",
        "evaluation" => "Increase owned Ship count"
      })

    scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))
    revision = Repo.get!(Revision, previous.fleet_strategy_revision_id)

    assert {:ok, _} =
             FleetAllocation.unwind_current_portfolio(scope, previous.fleet_generation_id)

    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "ORBITAL_STATION",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "SHIPYARD"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")
    ship_path = "/v2/my/ships/#{ship.symbol}"
    yard_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/shipyard"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 10_000}})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", ^yard_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "modificationsFee" => 100,
              "shipTypes" => [%{"type" => "SHIP_PROBE"}],
              "ships" => []
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, %{intent: %Intent{status: "completed"}}} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })

    projection =
      World.intelligence(agent, :shipyard, "X1-UX81", "X1-UX81-A1", DateTime.utc_now(), 300)

    assert projection.facts["ship_types"].freshness == :fresh
    assert projection.facts["ships"].value == []
    assert projection.facts["ships"].observing_ship_symbol == ship.symbol
  end

  test "active lower-priority commitments are not superseded by intelligence activation" do
    {agent, ship, portfolio, commitment} =
      claimed_ship(%{
        "objective" => "Chart useful waypoints",
        "kind" => "attain",
        "evaluation" => "Increase newly charted waypoint coverage"
      })

    revision = Repo.get!(Revision, portfolio.fleet_strategy_revision_id)

    revision =
      Repo.update!(
        Ecto.Changeset.change(revision, %{
          document: %{
            "objectives" => [
              %{
                "objective" => "Chart useful waypoints",
                "kind" => "attain",
                "evaluation" => "Increase newly charted waypoint coverage"
              },
              %{
                "objective" => "Grow credits",
                "kind" => "continuous",
                "evaluation" => "Maximize net credit growth over time"
              }
            ],
            "hard_constraints" => ["Keep at least 1,000 credits available"]
          }
        })
      )

    commitment = Repo.update!(Ecto.Changeset.change(commitment, objective_index: 1))
    scope = Scope.for_operator(Repo.get!(Operator, agent.operator_id))

    waypoint =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A2",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 2,
        "y" => 2,
        "traits" => []
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

    Req.Test.stub(SpaceTraders.API, fn _conn ->
      flunk("active commitments must retain their Fleet")
    end)

    assert {:error, :no_decision_relevant_intelligence} =
             FleetIntelligence.reconcile(scope, agent, revision, "X1-UX81", %{
               available_slots: 3,
               backpressure: :none
             })

    assert {:ok, %{portfolio_id: portfolio_id, commitment_id: commitment_id}} =
             FleetAllocation.current_ship_claim(agent, ship.symbol)

    assert portfolio_id == portfolio.id
    assert commitment_id == commitment.id
  end

  test "a persisted successful chart response is reconciled without another chart request" do
    {agent, ship, portfolio, commitment} =
      claimed_ship(%{
        "objective" => "Chart useful waypoints",
        "kind" => "attain",
        "evaluation" => "Increase newly charted waypoint coverage"
      })

    action = %{
      "kind" => "chart",
      "waypoint" => "X1-UX81-A1",
      "fleet_commitment_id" => commitment.id,
      "fleet_commitment_portfolio_id" => portfolio.id,
      "fleet_commitment_portfolio_version" => portfolio.version
    }

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        type: "acquire_intelligence",
        target_waypoint: "X1-UX81-A1",
        parameters: %{
          "system" => "X1-UX81",
          "subject_type" => "waypoint",
          "required_facts" => ["chart"],
          "freshness_seconds" => 300
        },
        in_flight_action: action
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("create-chart"),
        "/my/ships/#{ship.symbol}/chart",
        agent_id: agent.id,
        dependency_context: %{waypoint_symbol: "X1-UX81-A1"}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    {:ok, attempt} =
      MutationAttempts.record_outcome(attempt, :succeeded, %{status: 200})

    chart_time =
      attempt.sent_or_unknown_at
      |> DateTime.add(1, :second)
      |> DateTime.to_iso8601()

    ship_path = "/v2/my/ships/#{ship.symbol}"
    waypoint_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", ^waypoint_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "traits" => [],
              "chart" => %{
                "waypointSymbol" => "X1-UX81-A1",
                "submittedBy" => agent.symbol,
                "submittedOn" => chart_time
              }
            }
          })

        other ->
          flunk("unexpected replay: #{inspect(other)}")
      end
    end)

    assert :ok = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)
    assert MutationAttempts.get!(attempt.id).state == "succeeded"
  end

  defp observe_fuel_stop(agent, ship_symbol, symbol, x, y) do
    waypoint = Model.Waypoint.from_json(waypoint_body(symbol, "X1-UX81", "PLANET", x, y))

    market =
      Model.Market.from_json(%{
        "symbol" => symbol,
        "exports" => [],
        "imports" => [],
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

    assert {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoints")

    assert {:ok, _} =
             Intelligence.observe_market(agent, "X1-UX81", market,
               source: "get_market",
               observing_ship_symbol: ship_symbol
             )
  end

  defp waypoint_body(symbol, system, type, x \\ 1, y \\ 2) do
    %{
      "symbol" => symbol,
      "systemSymbol" => system,
      "type" => type,
      "x" => x,
      "y" => y,
      "traits" => [],
      "orbitals" => []
    }
  end

  defp claimed_ship(objective \\ %{"objective" => "Acquire useful intelligence"}) do
    operator =
      Repo.insert!(%Operator{email: "intelligence-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "INTELACQ",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    ship = Repo.insert!(%Ship{symbol: "INTELACQ-1", ship_type: "SHIP_PROBE", agent_id: agent.id})
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [objective],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction,
        replacement_symbols: %{},
        objective_progress: %{}
      })

    candidate = %PortfolioCandidate{
      id: "intelligence-#{ship.symbol}",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: 0,
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selection,
        %{evidence_references: [], expectations: %{}, calibration_version: "intelligence-v1"}
      )

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end

  defp unclaimed_intelligence_fixture(objective) do
    operator =
      Repo.insert!(%Operator{email: "demand-e2e-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "INTELACQ",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    ship = Repo.insert!(%Ship{symbol: "INTELACQ-1", ship_type: "SHIP_PROBE", agent_id: agent.id})
    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [objective],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    {agent, ship, revision, operator}
  end

  defp observe_stale_market(agent, ship, waypoint_symbol, observed_at) do
    listing =
      Model.Market.from_json(%{
        "symbol" => waypoint_symbol,
        "exports" => [%{"symbol" => "IRON_ORE"}],
        "imports" => [],
        "exchange" => [],
        "tradeGoods" => [
          %{
            "symbol" => "IRON_ORE",
            "type" => "EXPORT",
            "tradeVolume" => 20,
            "purchasePrice" => 12,
            "sellPrice" => 9
          }
        ]
      })

    Intelligence.observe_market(agent, "X1-UX81", listing,
      source: "get_market",
      observing_ship_symbol: ship.symbol,
      observed_at: observed_at
    )
  end

  test "runtime Market refresh demands cover only subjects with retained Listing evidence" do
    operator =
      Repo.insert!(%Operator{email: "refresh-scope-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "REFRESHSCOPE",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN",
        operator_id: operator.id
      })

    never_observed =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    observed =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A2",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 3,
        "y" => 4,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, never_observed, source: "get_waypoints")
    {:ok, _} = Intelligence.observe_waypoint(agent, observed, source: "get_waypoints")

    {:ok, _} =
      observe_stale_market(agent, agent, "X1-UX81-A2", DateTime.add(DateTime.utc_now(), -600))

    now = DateTime.utc_now()
    specs = FleetIntelligence.market_refresh_demand_specs(agent, "X1-UX81", now)

    # The never-observed Marketplace gets no runtime refresh demand: first-time
    # coverage is reset-start baseline work. The stale retained Listing is due
    # now.
    assert [%{subject: "market:X1-UX81:X1-UX81-A2", due_at: due_at, owner: "fleet_planning"}] =
             specs

    assert DateTime.compare(due_at, now) != :gt
  end

  test "baseline demand specs cover only Marketplaces without retained Listing evidence" do
    {agent, ship, _revision, _operator} =
      unclaimed_intelligence_fixture(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    never_observed =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    observed =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A2",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 3,
        "y" => 4,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, never_observed, source: "get_waypoints")
    {:ok, _} = Intelligence.observe_waypoint(agent, observed, source: "get_waypoints")

    {:ok, _} =
      observe_stale_market(agent, ship, "X1-UX81-A2", DateTime.add(DateTime.utc_now(), -600))

    now = DateTime.utc_now()
    specs = FleetIntelligence.baseline_market_demand_specs(agent, "X1-UX81", now)

    # Exactly the never-observed Marketplace: refresh work stays with the
    # refresh demand set.
    assert [
             %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               owner: "fleet_planning",
               due_at: due_at
             }
           ] = specs

    assert DateTime.compare(due_at, now) != :gt
  end

  test "baseline coverage keeps exactly one open demand due now and stays idempotent" do
    {agent, _ship, revision, _operator} =
      unclaimed_intelligence_fixture(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    marketplace =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, marketplace, source: "get_waypoints")

    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [demand] = Evidence.list_open_demands(agent)
    assert demand.subject == "market:X1-UX81:X1-UX81-A1"
    assert demand.owner == "fleet_planning"
    assert demand.strategy_revision_id == revision.id
    assert DateTime.compare(demand.due_at, DateTime.utc_now()) != :gt

    # Repeated synchronization never duplicates or replaces the durable
    # baseline demand: the persisted row remains the scheduled wakeup.
    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [demand] = Evidence.list_open_demands(agent)

    assert Evidence.due_demands() |> Enum.map(& &1.subject) == ["market:X1-UX81:X1-UX81-A1"]
  end

  test "a newly discovered Marketplace expands the open baseline demand set" do
    {agent, _ship, revision, _operator} =
      unclaimed_intelligence_fixture(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    first =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, first, source: "get_waypoints")
    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [%{id: first_demand_id, subject: "market:X1-UX81:X1-UX81-A1"}] =
             Evidence.list_open_demands(agent)

    second =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A2",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 3,
        "y" => 4,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, second, source: "get_waypoints")
    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    subjects = Evidence.list_open_demands(agent) |> Enum.map(& &1.subject) |> Enum.sort()
    assert subjects == ["market:X1-UX81:X1-UX81-A1", "market:X1-UX81:X1-UX81-A2"]

    # Authoritative Waypoint evidence expanded the set without touching the
    # first Marketplace's durable demand.
    expanded = Enum.find(Evidence.list_open_demands(agent), &(&1.id == first_demand_id))
    assert expanded.subject == "market:X1-UX81:X1-UX81-A1"
  end

  test "a superseding Strategy Revision withdraws baseline demands with preserved provenance" do
    {agent, _ship, revision, operator} =
      unclaimed_intelligence_fixture(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    marketplace =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, marketplace, source: "get_waypoints")

    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [%{id: demand_id}] = Evidence.list_open_demands(agent)

    scope = Scope.for_operator(operator)

    assert {:ok, _} =
             FleetStrategy.save_draft(
               scope,
               %{
                 "objectives" => [
                   %{
                     "objective" => "Grow credits",
                     "kind" => "continuous",
                     "evaluation" => "Maximize net credit growth over time",
                     "scope" => "recurring"
                   }
                 ],
                 "hard_constraints" => ["Keep at least 1,000 credits available"],
                 "preferences" => [],
                 "consequences" => "The Fleet may trade above the credit floor."
               },
               0
             )

    updated = FleetStrategy.get(scope)
    assert {:ok, _superseding} = FleetStrategy.activate(scope, updated.draft_version)

    # The baseline demand was withdrawn, never deleted, with its durable
    # Strategy provenance preserved.
    reloaded = Repo.get!(Evidence.ObservationDemand, demand_id)

    assert reloaded.withdrawn_at
    assert reloaded.strategy_revision_id == revision.id
    assert reloaded.subject == "market:X1-UX81:X1-UX81-A1"
    assert reloaded.owner == "fleet_planning"
    assert Evidence.list_open_demands(agent) == []
  end

  test "runtime sync withdraws a Market refresh demand that lost Marketplace relevance" do
    {agent, ship, revision, _operator} =
      unclaimed_intelligence_fixture(%{
        "objective" => "Grow credits",
        "kind" => "continuous",
        "evaluation" => "Maximize net credit growth over time"
      })

    marketplace =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, marketplace, source: "get_waypoints")

    {:ok, _} =
      observe_stale_market(agent, ship, "X1-UX81-A1", DateTime.add(DateTime.utc_now(), -600))

    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    assert [demand] =
             Evidence.list_open_demands(agent)
             |> Enum.filter(&(&1.subject == "market:X1-UX81:X1-UX81-A1"))

    # Newer Waypoint intelligence reclassifies the Waypoint: it is no longer a
    # known Marketplace, so the refresh demand loses Strategy relevance.
    reclassified =
      Model.Waypoint.from_json(%{
        "symbol" => "X1-UX81-A1",
        "systemSymbol" => "X1-UX81",
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "SHIPYARD"}]
      })

    {:ok, _} = Intelligence.observe_waypoint(agent, reclassified, source: "get_waypoints")

    assert :ok = FleetIntelligence.sync_market_observation_demands(agent, revision, "X1-UX81")

    # Withdrawn, never deleted, with its Strategy provenance preserved.
    reloaded = Repo.reload!(demand)
    assert reloaded.withdrawn_at
    assert reloaded.strategy_revision_id == revision.id
    assert reloaded.subject == "market:X1-UX81:X1-UX81-A1"
    assert reloaded.owner == "fleet_planning"
    assert Evidence.list_open_demands(agent) == []
  end
end
