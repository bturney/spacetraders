defmodule SpaceTraders.ResourceAcquisitionTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.{Agent, Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet.{Intent, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetPlanning
  alias SpaceTraders.FleetResources
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Timeline

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  test "fresh Strategy reconciliation claims a miner and counts one proven Cargo yield" do
    {scope, agent, revision, ship} = generation()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    extract_path = ship_path <> "/extract"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "mounts" => [mount()]
              })
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 100_000,
              "headquarters" => "X1-UX81-A1"
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"} ->
          Req.Test.json(conn, %{"data" => waypoint()})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "mounts" => [mount()]
              })
          })

        {"POST", ^extract_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "cooldown" => %{
                "shipSymbol" => ship.symbol,
                "remainingSeconds" => 30,
                "totalSeconds" => 30,
                "expiration" => DateTime.utc_now() |> DateTime.add(30) |> DateTime.to_iso8601()
              },
              "extraction" => %{
                "shipSymbol" => ship.symbol,
                "yield" => %{
                  "symbol" => "IRON_ORE",
                  "units" => 5
                }
              },
              "cargo" => %{
                "capacity" => 40,
                "units" => 17,
                "inventory" => [
                  %{"symbol" => "IRON_ORE", "units" => 17}
                ]
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "completed", type: "acquire_resources"} = intent} =
             FleetResources.reconcile(scope, agent, revision, "X1-UX81", capacity())

    assert intent.last_action_result["yield"] == %{"symbol" => "IRON_ORE", "units" => 5}
    assert_receive {"POST", "/v2/my/ships/RESOURCE-1/extract"}

    assert [%{event_type: "cooldown", status: "pending"}] =
             Timeline.pending_events(:ship, ship.symbol)

    portfolio = SpaceTraders.FleetAllocation.current_portfolio(scope, agent)
    assert portfolio.strategy_decision_episode.classification == :realized

    assert [%{"yield" => %{"units" => 5}}] =
             portfolio.strategy_decision_episode.actual_outcomes["resource_yields"]

    assert :ok = SpaceTraders.FleetAllocation.reconcile_completed_outcomes()

    assert [%{"yield" => %{"units" => 5}}] =
             Repo.get!(
               SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
               portfolio.strategy_decision_episode_id
             ).actual_outcomes["resource_yields"]
  end

  test "active Strategy discovers a remote extraction Waypoint for a new Agent" do
    {scope, agent, revision, ship} = generation()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = ship_path <> "/orbit"
    navigate_path = ship_path <> "/navigate"
    waypoints_path = "/v2/systems/X1-UX81/waypoints"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol, %{"mounts" => [mount()]})]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 100_000,
              "headquarters" => "X1-UX81-A1"
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"} ->
          Req.Test.json(conn, %{"data" => %{waypoint() | "type" => "PLANET"}})

        {"GET", ^waypoints_path} ->
          Req.Test.json(conn, %{
            "data" => [
              %{waypoint() | "type" => "PLANET"},
              %{waypoint() | "symbol" => "X1-UX81-A2", "type" => "ASTEROID"}
            ],
            "meta" => %{"total" => 2, "page" => 1, "limit" => 20}
          })

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol, %{"mounts" => [mount()]})})

        {"POST", ^orbit_path} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "nav" =>
                nav_body("IN_TRANSIT",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  destination: "X1-UX81-A2"
                ),
              "fuel" => %{"capacity" => 200, "current" => 100}
            }
          })
      end
    end)

    assert {:ok, %Intent{status: "waiting", target_waypoint: "X1-UX81-A2"}} =
             FleetResources.reconcile(scope, agent, revision, "X1-UX81", capacity())

    assert_receive {"GET", ^waypoints_path}
    assert_receive {"POST", ^orbit_path}
    assert_receive {"POST", ^navigate_path}
  end

  test "planner rejects stale Waypoint evidence, full Cargo and active cooldown" do
    {_scope, _agent, revision, _stored_ship} = generation()
    as_of = DateTime.utc_now()
    ship = miner_ship()
    waypoint = resource_waypoint(as_of)

    assert {:ok, %{candidate_contributions: [_]}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [ship],
               waypoints: [waypoint]
             })

    stale = put_in(waypoint, [:facts, "type", :freshness], :stale)

    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [ship],
               waypoints: [stale]
             })

    full = put_in(ship.cargo.units, ship.cargo.capacity)

    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [full],
               waypoints: [waypoint]
             })

    cooling = put_in(ship.cooldown.remaining_seconds, 15)

    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [cooling],
               waypoints: [waypoint]
             })
  end

  test "planner chooses siphoning and refining only with the matching Ship capability and Cargo" do
    {_scope, _agent, revision, _stored_ship} = generation()
    as_of = DateTime.utc_now()
    gas = put_in(resource_waypoint(as_of).facts["type"].value, "GAS_GIANT")

    siphon =
      ship_body("RESOURCE-1", %{
        "nav" => nav_body("IN_ORBIT"),
        "mounts" => [%{mount() | "symbol" => "MOUNT_GAS_SIPHON_I"}]
      })
      |> Model.Ship.from_json()

    assert {:ok, %{candidate_contributions: [%{resource: %{mode: :siphon}}]}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [siphon],
               waypoints: [gas]
             })

    ore =
      ship_body("RESOURCE-1", %{
        "nav" => nav_body("IN_ORBIT"),
        "modules" => [%{"symbol" => "MODULE_MINERAL_PROCESSOR_I"}],
        "cargo" => %{
          "capacity" => 200,
          "units" => 100,
          "inventory" => [%{"symbol" => "IRON_ORE", "units" => 100}]
        }
      })
      |> Model.Ship.from_json()

    assert {:ok, %{candidate_contributions: [%{resource: %{mode: :refine, produce: "IRON"}}]}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [ore],
               waypoints: [resource_waypoint(as_of)]
             })

    insufficient =
      put_in(ore.cargo.inventory, [%Model.ShipCargoItem{symbol: "IRON_ORE", units: 99}])

    assert {:ok, %{candidate_contributions: []}} =
             FleetPlanning.plan_resources(revision, 0, %{
               as_of: as_of,
               ships: [insufficient],
               waypoints: [resource_waypoint(as_of)]
             })
  end

  test "refining runs under a Claim and verifies produced and consumed Cargo" do
    {scope, agent, revision, ship} = generation()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    refine_path = ship_path <> "/refine"

    ore_cargo = %{
      "capacity" => 200,
      "units" => 100,
      "inventory" => [%{"symbol" => "IRON_ORE", "units" => 100}]
    }

    live_body =
      ship_body(ship.symbol, %{
        "nav" => nav_body("IN_ORBIT"),
        "modules" => [%{"symbol" => "MODULE_ORE_REFINERY_I"}],
        "cargo" => ore_cargo
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [live_body]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 100_000,
              "headquarters" => "X1-UX81-A1"
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"} ->
          Req.Test.json(conn, %{"data" => waypoint()})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => live_body})

        {"POST", ^refine_path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body) == %{"produce" => "IRON"}

          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => %{
                "capacity" => 200,
                "units" => 10,
                "inventory" => [%{"symbol" => "IRON", "units" => 10}]
              },
              "cooldown" => %{
                "shipSymbol" => ship.symbol,
                "remainingSeconds" => 30,
                "totalSeconds" => 30,
                "expiration" => DateTime.utc_now() |> DateTime.add(30) |> DateTime.to_iso8601()
              },
              "produced" => [%{"tradeSymbol" => "IRON", "units" => 10}],
              "consumed" => [%{"tradeSymbol" => "IRON_ORE", "units" => 100}]
            }
          })
      end
    end)

    assert {:ok,
            %Intent{
              status: "completed",
              last_action_result: %{
                "yield" => %{"produced" => [%{"tradeSymbol" => "IRON", "units" => 10}]}
              }
            }} = FleetResources.reconcile(scope, agent, revision, "X1-UX81", capacity())

    assert_receive {"POST", ^refine_path}
  end

  test "a claimed Survey is retained in the root Intent and its cooldown rearms after restart" do
    {scope, agent, revision, ship} = generation()
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    survey_path = ship_path <> "/survey"
    surveyed_extract_path = ship_path <> "/extract/survey"
    cooldown_at = DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {conn.method, conn.request_path})

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "mounts" => [mount(), surveyor()]
              })
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 100_000,
              "headquarters" => "X1-UX81-A1"
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1"} ->
          Req.Test.json(conn, %{"data" => waypoint()})

        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body("IN_ORBIT"),
                "mounts" => [mount(), surveyor()]
              })
          })

        {"POST", ^survey_path} ->
          Req.Test.json(conn, %{
            "data" => %{
              "cooldown" => %{
                "shipSymbol" => ship.symbol,
                "remainingSeconds" => 60,
                "totalSeconds" => 60,
                "expiration" => cooldown_at
              },
              "surveys" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "signature" => "SIGNED",
                  "expiration" =>
                    DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  "size" => "SMALL",
                  "deposits" => [%{"symbol" => "IRON_ORE"}]
                }
              ]
            }
          })

        {"POST", ^surveyed_extract_path} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          assert Jason.decode!(body)["signature"] == "SIGNED"

          Req.Test.json(conn, %{
            "data" => %{
              "cooldown" => %{
                "shipSymbol" => ship.symbol,
                "remainingSeconds" => 60,
                "totalSeconds" => 60,
                "expiration" => cooldown_at
              },
              "extraction" => %{
                "shipSymbol" => ship.symbol,
                "yield" => %{"symbol" => "IRON_ORE", "units" => 5}
              },
              "cargo" => %{
                "capacity" => 40,
                "units" => 17,
                "inventory" => [
                  %{"symbol" => "IRON_ORE", "units" => 17}
                ]
              },
              "events" => []
            }
          })
      end
    end)

    assert {:ok,
            %Intent{
              status: "waiting",
              parameters: %{
                "survey" => %{"signature" => "SIGNED"}
              }
            } = intent} = FleetResources.reconcile(scope, agent, revision, "X1-UX81", capacity())

    assert_receive {"POST", ^survey_path}
    refute_receive {"POST", "/v2/my/ships/RESOURCE-1/extract/survey"}

    assert [%{event_type: "cooldown", payload: %{"intent_id" => id}}] =
             Timeline.pending_events(:ship, ship.symbol)

    assert id == intent.id
    assert :ok = ShipServer.stop(ship.symbol)
    assert {:ok, _pid} = ShipServer.ensure_started(agent, ship.symbol)
    assert {:error, :cooldown_active} = ShipServer.ensure_ready(ship.symbol)

    recovered =
      ship_body(ship.symbol, %{
        "nav" => nav_body("IN_ORBIT"),
        "mounts" => [mount(), surveyor()]
      })
      |> Model.Ship.from_json()

    assert :ok = Intents.reconcile(agent.id, ship.symbol, recovered, :cooldown, intent.id)
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)

    assert_receive {"POST", ^surveyed_extract_path}
  end

  defp generation do
    operator = Repo.insert!(%Operator{email: "resource-#{System.unique_integer()}@example.com"})

    agent =
      Repo.insert!(%Agent{
        operator_id: operator.id,
        symbol: "RESOURCE",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "TOKEN"
      })

    ship =
      Repo.insert!(%Ship{
        agent_id: agent.id,
        symbol: "RESOURCE-1",
        ship_type: "SHIP_MINING_DRONE"
      })

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        source: "operator",
        activated_at: DateTime.utc_now(:second),
        document: %{
          "objectives" => [
            %{
              "objective" => "Extract resources",
              "kind" => "continuous",
              "evaluation" => "Acquire ore"
            }
          ],
          "hard_constraints" => ["Keep at least 1,000 credits available"]
        }
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

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

    {Scope.for_operator(operator), agent, revision, ship}
  end

  defp capacity, do: %{available_slots: 10, backpressure: :none}

  defp waypoint,
    do: %{
      "symbol" => "X1-UX81-A1",
      "systemSymbol" => "X1-UX81",
      "type" => "ASTEROID",
      "x" => 0,
      "y" => 0,
      "traits" => []
    }

  defp mount,
    do: %{
      "symbol" => "MOUNT_MINING_LASER_I",
      "name" => "Laser",
      "description" => "Mining laser",
      "strength" => 1,
      "requirements" => %{"power" => 1, "crew" => 1}
    }

  defp surveyor, do: %{mount() | "symbol" => "MOUNT_SURVEYOR_I"}

  defp miner_ship do
    ship_body("RESOURCE-1", %{"nav" => nav_body("IN_ORBIT"), "mounts" => [mount()]})
    |> Model.Ship.from_json()
  end

  defp resource_waypoint(as_of) do
    %{
      symbol: "X1-UX81-A1",
      subject: {:waypoint, "X1-UX81", "X1-UX81-A1"},
      facts: %{
        "type" => %{
          state: "known",
          freshness: :fresh,
          value: "ASTEROID",
          observed_at: as_of,
          observation_id: 123,
          source: "Public Waypoint observation"
        }
      }
    }
  end
end
