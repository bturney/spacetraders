defmodule SpaceTraders.IntelligenceAcquisitionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetPlanning
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

  test "an insufficient-fuel navigation at a confirmed fuel Market refuels and continues" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    navigate_path = "#{ship_path}/navigate"
    dock_path = "#{ship_path}/dock"
    orbit_path = "#{ship_path}/orbit"
    refuel_path = "#{ship_path}/refuel"
    market_path = "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"
    arrival = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

    Process.put(:fuel_test_navigate_calls, 0)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "fuel" => %{
                  "capacity" => 200,
                  "current" => 55,
                  "consumed" => %{"amount" => 145, "timestamp" => "2026-01-01T00:00:00.000Z"}
                }
              })
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

        {"POST", ^navigate_path} ->
          count = Process.get(:fuel_test_navigate_calls, 0)
          Process.put(:fuel_test_navigate_calls, count + 1)

          if count == 0 do
            conn
            |> Plug.Conn.put_status(400)
            |> Req.Test.json(%{
              "error" => %{
                "code" => 4203,
                "message" => "Navigate request failed. Ship requires 12 more fuel.",
                "data" => %{"fuelAvailable" => 55, "fuelRequired" => 67}
              }
            })
          else
            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 200},
                "nav" => nav_body("IN_TRANSIT", arrival: arrival, destination: "X1-UX81-A2")
              }
            })
          end

        {"POST", ^dock_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("DOCKED")}})

        {"POST", ^refuel_path} ->
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
    assert_receive {"POST", ^navigate_path}
    assert_receive {"POST", ^dock_path}
    assert_receive {"GET", ^market_path}
    assert_receive {"POST", ^refuel_path}
    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
    assert Process.get(:fuel_test_navigate_calls) == 2
    assert %Intent{parameters: %{"refuel" => "to_capacity"}} = Repo.get!(Intent, intent.id)
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
end
