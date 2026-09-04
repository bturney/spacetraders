defmodule SpaceTraders.IntentsTest do
  # navigate, boot reconciliation, and re-arm start ship GenServers, which read
  # and write the timeline as separate processes, so the sandbox must be shared
  # (not async).
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Job, JobBlocker, Ship, ShipServer}
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.Timeline
  alias SpaceTraders.Timeline.Event

  import SpaceTraders.ShipBody

  setup do
    on_exit(fn -> ShipServer.stop_all() end)
    :ok
  end

  defp future_iso(seconds \\ 3600) do
    DateTime.add(DateTime.utc_now(), seconds, :second)
    |> DateTime.to_iso8601()
  end

  defp navigate_response(status, arrival, destination) do
    %{
      "fuel" => %{"capacity" => 200, "current" => 80},
      "nav" => nav_body(status, arrival: arrival, destination: destination)
    }
  end

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
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-NAV-SHIP",
               %Intents.Navigate{waypoint: " X1-UX81-A2 "}
             )
  end

  test "requests a closed Buy Goods goal through Manual Control" do
    agent = agent_fixture("INTENTS-BUY")
    ship_fixture(agent, "INTENTS-BUY-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-BUY-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-BUY-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/my/agent", "GET"} ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 100}})

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{"symbol" => "IRON_ORE", "purchasePrice" => 10, "tradeVolume" => 5}
              ]
            }
          })

        {"/v2/my/ships/INTENTS-BUY-SHIP/purchase", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{"symbol" => agent.symbol, "credits" => 50},
              "cargo" => %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              "transaction" => %{
                "shipSymbol" => "INTENTS-BUY-SHIP",
                "tradeSymbol" => "IRON_ORE",
                "type" => "PURCHASE",
                "units" => 5,
                "pricePerUnit" => 10,
                "totalPrice" => 50,
                "waypointSymbol" => "X1-UX81-A1",
                "timestamp" => "2026-01-01T00:00:00.000Z"
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{type: "buy", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-BUY-SHIP",
               %Intents.BuyGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 5,
                 constraints: %{max_unit_price: 10, reserve_credits: 25}
               }
             )
  end

  test "requests a closed Sell Goods goal through Manual Control" do
    agent = agent_fixture("INTENTS-SELL")
    ship_fixture(agent, "INTENTS-SELL-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-SELL-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-SELL-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "tradeGoods" => [
                %{"symbol" => "IRON_ORE", "sellPrice" => 25, "tradeVolume" => 5}
              ]
            }
          })

        {"/v2/my/ships/INTENTS-SELL-SHIP/sell", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{"symbol" => agent.symbol, "credits" => 125},
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "transaction" => %{
                "shipSymbol" => "INTENTS-SELL-SHIP",
                "tradeSymbol" => "IRON_ORE",
                "type" => "SELL",
                "units" => 5,
                "pricePerUnit" => 25,
                "totalPrice" => 125,
                "waypointSymbol" => "X1-UX81-A1",
                "timestamp" => "2026-01-01T00:00:00.000Z"
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{type: "sell", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-SELL-SHIP",
               %Intents.SellGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 5,
                 constraints: %{min_price: 20, min_total: 100}
               }
             )
  end

  test "requests a closed Deliver Goods goal through Manual Control" do
    agent = agent_fixture("INTENTS-DELIVER")
    ship_fixture(agent, "INTENTS-DELIVER-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-DELIVER-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-DELIVER-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              }
            }
          })

        {"/v2/my/contracts", "GET"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "INTENTS-CONTRACT",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2030-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A1",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => 0
                    }
                  ]
                }
              }
            ]
          })

        {"/v2/my/contracts/INTENTS-CONTRACT/deliver", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "contract" => %{
                "id" => "INTENTS-CONTRACT",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2030-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A1",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => 5
                    }
                  ]
                }
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{caller: "manual", type: "deliver", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-DELIVER-SHIP",
               %Intents.DeliverGoods{
                 recipient: %Intents.ContractRecipient{
                   contract_id: "INTENTS-CONTRACT",
                   waypoint: "X1-UX81-A1"
                 },
                 trade_good: "IRON_ORE",
                 quantity: 5
               }
             )
  end

  test "requests a Construction recipient through Deliver Goods" do
    agent = agent_fixture("INTENTS-CONSTRUCTION")
    ship_fixture(agent, "INTENTS-CONSTRUCTION-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-CONSTRUCTION-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-CONSTRUCTION-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{
                "capacity" => 40,
                "units" => 5,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 5}]
              },
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => false,
              "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 7}]
            }
          })

        {"/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply", "POST"} ->
          assert conn.body_params == %{
                   "shipSymbol" => "INTENTS-CONSTRUCTION-SHIP",
                   "tradeSymbol" => "IRON_ORE",
                   "units" => 5
                 }

          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "construction" => %{
                "symbol" => "X1-UX81-A1",
                "isComplete" => false,
                "materials" => [
                  %{"tradeSymbol" => "IRON_ORE", "required" => 20, "fulfilled" => 12}
                ]
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{caller: "manual", type: "deliver", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-CONSTRUCTION-SHIP",
               %Intents.DeliverGoods{
                 recipient: %Intents.ConstructionRecipient{
                   system: "X1-UX81",
                   waypoint: "X1-UX81-A1"
                 },
                 trade_good: "IRON_ORE",
                 quantity: 5
               }
             )
  end

  test "requests a closed Install Module goal through Manual Control" do
    agent = agent_fixture("INTENTS-INSTALL")
    ship_fixture(agent, "INTENTS-INSTALL-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-INSTALL-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-INSTALL-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "frame" => %{"moduleSlots" => 2},
              "modules" => [],
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{
                "capacity" => 40,
                "units" => 1,
                "inventory" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}]
              },
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/my/ships/INTENTS-INSTALL-SHIP/modules/install", "POST"} ->
          assert conn.body_params == %{"symbol" => "MODULE_CARGO_HOLD_I"}

          Req.Test.json(conn, %{
            "data" => %{
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []}
            }
          })
      end
    end)

    assert {:ok, %Intent{type: "install_module", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-INSTALL-SHIP",
               %Intents.InstallModule{module_symbol: "MODULE_CARGO_HOLD_I"}
             )
  end

  test "requests a closed Remove Module goal through Manual Control" do
    agent = agent_fixture("INTENTS-REMOVE")
    ship_fixture(agent, "INTENTS-REMOVE-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-REMOVE-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-REMOVE-SHIP",
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "frame" => %{"moduleSlots" => 2},
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{
                "capacity" => 40,
                "units" => 1,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 1}]
              },
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/my/ships/INTENTS-REMOVE-SHIP/modules/remove", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "modules" => [],
              "cargo" => %{
                "capacity" => 40,
                "units" => 2,
                "inventory" => [
                  %{"symbol" => "IRON_ORE", "units" => 1},
                  %{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}
                ]
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{type: "remove_module", status: "completed"}} =
             Intents.request(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-REMOVE-SHIP",
               %Intents.RemoveModule{
                 module_symbol: "MODULE_CARGO_HOLD_I",
                 authorized_removals: %{"MODULE_CARGO_HOLD_I" => 1}
               }
             )
  end

  test "accepts Buy Goods ownership from a Market Trading Job" do
    agent = agent_fixture("INTENTS-BUY-JOB")
    ship = ship_fixture(agent, "INTENTS-BUY-JOB-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "market_trading",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 10
      })

    assert {:error, :invalid_buy_constraints} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.BuyGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 1,
                 constraints: %{unsupported: 1}
               }
             )
  end

  test "does not let a stale paused Outfitting Job request module removal" do
    agent = agent_fixture("INTENTS-STALE-OUTFIT")
    ship = ship_fixture(agent, "INTENTS-STALE-OUTFIT-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "outfitting",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 1
      })

    Repo.update!(Ecto.Changeset.change(job, status: "paused"))

    assert {:error, :invalid_module_intent} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.RemoveModule{
                 module_symbol: "MODULE_CARGO_HOLD_I",
                 authorized_removals: %{"MODULE_CARGO_HOLD_I" => 1}
               }
             )

    assert Repo.all(Intent) == []
  end

  test "requests module removal through a running Outfitting Job" do
    agent = agent_fixture("INTENTS-OUTFIT-REMOVE")
    ship = ship_fixture(agent, "INTENTS-OUTFIT-REMOVE-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "outfitting",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 1,
        progress: %{"authorized_removals" => %{"MODULE_CARGO_HOLD_I" => 2}}
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-OUTFIT-REMOVE-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => ship.symbol,
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "frame" => %{"moduleSlots" => 2},
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "name" => "Cargo Hold I"}],
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/my/ships/INTENTS-OUTFIT-REMOVE-SHIP/modules/remove", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "modules" => [],
              "cargo" => %{
                "capacity" => 40,
                "units" => 1,
                "inventory" => [%{"symbol" => "MODULE_CARGO_HOLD_I", "units" => 1}]
              }
            }
          })
      end
    end)

    assert {:ok, %Intent{caller: "job", job_id: job_id, status: "completed"}} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.RemoveModule{
                 module_symbol: "MODULE_CARGO_HOLD_I",
                 authorized_removals: %{}
               }
             )

    assert job_id == job.id
  end

  test "requests a running Job Navigate without Manual Control confirmation" do
    agent = agent_fixture("INTENTS-JOB-NAV")
    ship = ship_fixture(agent, "INTENTS-JOB-NAV-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "miner",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A2",
        cargo_threshold: 10
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {"/v2/my/ships/INTENTS-JOB-NAV-SHIP", "GET"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "INTENTS-JOB-NAV-SHIP",
              "nav" => %{
                "status" => "IN_ORBIT",
                "waypointSymbol" => "X1-UX81-A1",
                "systemSymbol" => "X1-UX81",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        {"/v2/my/ships/INTENTS-JOB-NAV-SHIP/navigate", "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "nav" => %{
                "status" => "IN_TRANSIT",
                "waypointSymbol" => "X1-UX81-A1",
                "route" => %{
                  "departure" => %{"symbol" => "X1-UX81-A1"},
                  "destination" => %{"symbol" => "X1-UX81-A2"},
                  "arrival" => "2030-01-01T00:00:00Z"
                }
              },
              "fuel" => %{"current" => 90, "capacity" => 100}
            }
          })
      end
    end)

    assert {:ok, %Intent{id: intent_id, caller: "job", job_id: job_id, status: "waiting"}} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.Navigate{waypoint: "X1-UX81-A2"}
             )

    assert job_id == job.id
    assert Repo.get!(Intent, intent_id).status == "waiting"
  end

  test "rejects a Navigate request from a paused Job" do
    agent = agent_fixture("INTENTS-PAUSED-JOB")
    ship = ship_fixture(agent, "INTENTS-PAUSED-JOB-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "miner",
        status: "paused",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A2",
        cargo_threshold: 10
      })

    assert {:error, :invalid_intent_owner} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.Navigate{waypoint: "X1-UX81-A2"}
             )

    assert Repo.all(Intent) == []
  end

  test "refreshes the Ship when a Job Sell Goods request has no live observation" do
    agent = agent_fixture("INTENTS-JOB-SELL-REFRESH")
    ship = ship_fixture(agent, "INTENTS-JOB-SELL-REFRESH-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "market_trading",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 10
      })

    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships/INTENTS-JOB-SELL-REFRESH-SHIP" ->
          assert conn.method == "GET"
          send(test_pid, :job_sell_ship_refreshed)

          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => ship.symbol,
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "DOCKED",
                "flightMode" => "CRUISE"
              },
              "fuel" => %{"current" => 100, "capacity" => 100},
              "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
              "cooldown" => %{"remainingSeconds" => 0}
            }
          })

        _ ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"error" => %{"message" => "market unavailable"}})
      end
    end)

    assert {:ok, %Intent{caller: "job", status: "blocked"}} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.SellGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 1,
                 constraints: %{min_price: 1}
               }
             )

    assert_received :job_sell_ship_refreshed
  end

  test "rejects a Sell Goods request when the persisted Job is no longer running" do
    agent = agent_fixture("INTENTS-STALE-JOB-SELL")
    ship = ship_fixture(agent, "INTENTS-STALE-JOB-SELL-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "market_trading",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 10
      })

    Repo.update!(Ecto.Changeset.change(job, status: "paused"))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => ship.symbol,
          "nav" => %{
            "systemSymbol" => "X1-UX81",
            "waypointSymbol" => "X1-UX81-A1",
            "status" => "DOCKED",
            "flightMode" => "CRUISE"
          },
          "fuel" => %{"current" => 100, "capacity" => 100},
          "cargo" => %{"capacity" => 40, "units" => 0, "inventory" => []},
          "cooldown" => %{"remainingSeconds" => 0}
        }
      })
    end)

    assert {:error, :invalid_intent_owner} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.SellGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 1,
                 constraints: %{min_price: 1}
               }
             )

    assert Repo.all(Intent) == []
  end

  test "does not persist a Sell Goods Intent when Ship refresh fails" do
    agent = agent_fixture("INTENTS-JOB-SELL-FAILED-REFRESH")
    ship = ship_fixture(agent, "INTENTS-JOB-SELL-FAILED-REFRESH-SHIP")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "market_trading",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 10
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(503)
      |> Req.Test.json(%{"error" => %{"message" => "unavailable"}})
    end)

    assert {:error, _reason} =
             Intents.request(
               agent,
               %Intents.JobOwner{job: job},
               ship.symbol,
               %Intents.SellGoods{
                 market: "X1-UX81-A1",
                 trade_good: "IRON_ORE",
                 quantity: 1,
                 constraints: %{min_price: 1}
               }
             )

    assert Repo.all(Intent) == []
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

  test "Manual Control cannot request an Intent for another Operator's Agent" do
    owner = Repo.insert!(%Operator{email: "intent-owner@example.com"})
    other_operator = Repo.insert!(%Operator{email: "other-operator@example.com"})
    agent = agent_fixture("INTENTS-OWNED", owner.id)
    ship_fixture(agent, "INTENTS-OWNED-SHIP")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("unauthorized request reached the game API: #{conn.method} #{conn.request_path}")
    end)

    assert {:error, :agent_not_owned} =
             Intents.request(
               Scope.for_operator(other_operator),
               agent,
               %Intents.ManualControl{},
               "INTENTS-OWNED-SHIP",
               %Intents.Navigate{waypoint: "X1-UX81-A2"}
             )

    assert Repo.all(Intent) == []
  end

  test "Manual Control cannot review or block another Operator's Agent" do
    owner = Repo.insert!(%Operator{email: "review-owner@example.com"})
    other_operator = Repo.insert!(%Operator{email: "other-review-operator@example.com"})
    agent = agent_fixture("INTENTS-REVIEW-OWNED", owner.id)
    ship_fixture(agent, "INTENTS-REVIEW-OWNED-SHIP")
    other_scope = Scope.for_operator(other_operator)

    assert {:error, :agent_not_owned} =
             Intents.review(
               other_scope,
               agent,
               %Intents.ManualControl{},
               "INTENTS-REVIEW-OWNED-SHIP",
               "X1-UX81-A2",
               %{method: "navigate"}
             )

    assert {:error, :agent_not_owned} =
             Intents.block_review(
               other_scope,
               agent,
               %Intents.ManualControl{},
               "INTENTS-REVIEW-OWNED-SHIP",
               "X1-UX81-A2",
               :route_unavailable
             )

    assert Repo.all(Intent) == []
  end

  test "Manual Control cannot confirm or stop another Operator's Intent" do
    owner = Repo.insert!(%Operator{email: "stop-owner@example.com"})
    other_operator = Repo.insert!(%Operator{email: "other-stop-operator@example.com"})
    agent = agent_fixture("INTENTS-STOP-OWNED", owner.id)
    ship = ship_fixture(agent, "INTENTS-STOP-OWNED-SHIP")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        target_waypoint: "X1-UX81-A2",
        status: "awaiting_confirmation",
        review_revision: 1
      })

    other_scope = Scope.for_operator(other_operator)

    assert {:error, :intent_not_found} =
             Intents.confirm(other_scope, %Intents.ManualControl{}, intent.id, 1)

    assert {:error, :intent_not_found} =
             Intents.stop(other_scope, %Intents.ManualControl{}, intent.id)

    assert %Intent{status: "awaiting_confirmation"} = Repo.get!(Intent, intent.id)
  end

  test "reviews and blocks Manual Control Navigate through the seam" do
    agent = agent_fixture("INTENTS-REVIEW")
    ship_fixture(agent, "INTENTS-REVIEW-SHIP")

    assert {:ok, %Intent{status: "awaiting_confirmation", review_revision: 1}} =
             Intents.review(
               manual_scope(agent),
               agent,
               %Intents.ManualControl{},
               "INTENTS-REVIEW-SHIP",
               "X1-UX81-A2",
               %{method: "jump", source_waypoint: "X1-UX81-A1"}
             )

    assert {:ok, %Intent{status: "blocked"}} =
             Intents.block_review(
               manual_scope(agent),
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

    assert :ok = Intents.stop(manual_scope(agent), %Intents.ManualControl{}, intent.id)
    assert %Intent{status: "stopped"} = Repo.get!(Intent, intent.id)
  end

  test "binds stopping to the requested Ship" do
    agent = agent_fixture("INTENTS-MISMATCH")
    ship = ship_fixture(agent, "INTENTS-SHIP-ONE")
    ship_fixture(agent, "INTENTS-SHIP-TWO")
    intent = Repo.insert!(%Intent{ship_id: ship.id, target_waypoint: "X1-UX81-A2"})

    assert {:error, :intent_ship_mismatch} =
             Intents.stop(
               manual_scope(agent),
               %Intents.ManualControl{},
               "INTENTS-SHIP-TWO",
               intent.id
             )

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
             Intents.stop(manual_scope(agent), %Intents.ManualControl{}, intent.id)

    assert %Intent{status: "waiting"} = Repo.get!(Intent, intent.id)
  end

  describe "remote route reviews and confirmation" do
    test "shows the reviewed flight mode without inventing a fuel budget" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()
      {:ok, mode} = Agent.start_link(fn -> "CRUISE" end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path})

        case conn.request_path do
          "/v2/my/ships/FLEET-SHIP" ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-G1",
                    "status" => "IN_ORBIT",
                    "flightMode" => Agent.get(mode, & &1)
                  }
                })
            })

          "/v2/my/agent" ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          "/v2/systems/X1-UX81/waypoints" ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-G1" ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          "/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate" ->
            Req.Test.json(conn, %{"data" => %{"connections" => ["X2-UX81-G1"]}})

          "/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction" ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          "/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate" ->
            Req.Test.json(conn, %{"data" => %{"connections" => ["X1-UX81-G1"]}})

          "/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market" ->
            Req.Test.json(conn, %{
              "data" => %{"tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]}
            })
        end
      end)

      assert {:ok, preview} = Intents.jump_preview(agent, "FLEET-SHIP", "X2-UX81-G1")
      assert preview.flight_mode == "CRUISE"
      refute Map.has_key?(preview, :fuel_budget)
      refute Map.has_key?(preview, :time_budget_seconds)

      assert {:ok, %Intent{id: reviewed_id, review_revision: revision}} =
               Intents.review(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 "X2-UX81-G1",
                 preview
               )

      assert {:error, :review_revision_stale} =
               Intents.confirm(
                 manual_scope(agent),
                 %Intents.ManualControl{},
                 reviewed_id,
                 revision + 1
               )

      for unsupported <- ~w(DRIFT STEALTH BURN) do
        Agent.update(mode, fn _ -> unsupported end)

        assert {:ok, preview} = Intents.jump_preview(agent, "FLEET-SHIP", "X2-UX81-G1")
        assert preview.flight_mode == unsupported
        refute Map.has_key?(preview, :fuel_budget)
      end
    end

    test "warps with an authoritatively installed Warp Drive and persists arrival evidence" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      arrival = future_iso()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-A1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/ships/FLEET-SHIP/warp", "POST"} ->
            assert conn.body_params == %{"waypointSymbol" => "X2-UX81-A3"}

            Req.Test.json(conn, %{
              "data" => %{
                "fuel" => %{"capacity" => 200, "current" => 80},
                "nav" =>
                  nav_body("IN_TRANSIT",
                    arrival: arrival,
                    destination: "X2-UX81-A3",
                    systemSymbol: "X2-UX81"
                  )
              }
            })
        end
      end)

      assert {:ok, preview} = Intents.warp_preview(agent, "FLEET-SHIP", "X2-UX81-A3")
      assert preview.warp_drive == "MODULE_WARP_DRIVE_I"
      assert preview.flight_mode == "CRUISE"
      assert preview.fuel_current == 150

      assert {:ok, %Intent{id: warp_id, review_revision: warp_revision}} =
               Intents.review(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 "X2-UX81-A3",
                 preview
               )

      assert {:ok, %Intent{status: "waiting", in_flight_action: %{"kind" => "warp"}}} =
               Intents.confirm(
                 manual_scope(agent),
                 %Intents.ManualControl{},
                 warp_id,
                 warp_revision
               )

      assert [%Event{event_type: "arrival", payload: %{"destination" => "X2-UX81-A3"}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "does not infer a Warp Drive from a module symbol not installed on the Ship" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert conn.request_path == "/v2/my/ships/FLEET-SHIP"

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I"}],
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "IN_ORBIT",
                "flightMode" => "CRUISE"
              }
            })
        })
      end)

      assert {:error, :warp_drive_missing} =
               Intents.warp_preview(agent, "FLEET-SHIP", "X2-UX81-A3")
    end

    test "persists allowed_methods with the reviewed Intent" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-A1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })
        end
      end)

      assert {:ok, preview} = Intents.warp_preview(agent, "FLEET-SHIP", "X2-UX81-A3")

      # Review with allowed_methods: ["jump"] persists the restriction
      assert {:ok, %Intent{parameters: params}} =
               Intents.review(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 "X2-UX81-A3",
                 preview,
                 allowed_methods: ["jump"]
               )

      assert params["allowed_methods"] == ["jump"]
      assert params["review_method"] == "warp"

      # Review without allowed_methods defaults to both
      assert {:ok, %Intent{parameters: params2}} =
               Intents.review(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 "X2-UX81-A3",
                 preview
               )

      assert params2["allowed_methods"] == ["jump", "warp"]
    end

    test "method_selection returns jump-only when allowed_methods restricts to jump" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-G1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })
        end
      end)

      # Even though warp is viable, restricting to jump-only excludes it
      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1",
                 allowed_methods: ["jump"]
               )

      assert selection.selected == "jump"
      assert {"jump", _} = List.keyfind!(selection.viable, "jump", 0)
      assert {"warp", :method_not_allowed} = List.keyfind!(selection.rejected, "warp", 0)
    end
  end

  describe "manual Navigate Intents" do
    test "persists a refreshed review when the reviewed Ship location changed" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      {:ok, state} = Agent.start_link(fn -> %{waypoint: "X1-UX81-G1"} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            waypoint = Agent.get(state, & &1.waypoint)

            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: waypoint)
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })

          {path, method} ->
            flunk("unexpected request #{method} #{path}")
        end
      end)

      assert {:ok, preview} = Intents.jump_preview(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert {:ok, %Intent{id: intent_id}} =
               Intents.review(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 "X2-UX81-G1",
                 preview
               )

      Agent.update(state, &%{&1 | waypoint: "X1-UX81-A2"})

      assert {:ok, %Intent{status: "awaiting_confirmation", review_revision: 2}} =
               Intents.confirm(manual_scope(agent), %Intents.ManualControl{}, intent_id, 1)
    end

    test "jumps through connected complete gates and completes from a fresh Ship read" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()
      {:ok, state} = Agent.start_link(fn -> %{jumped?: false} end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path, conn.method})

        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            destination = if Agent.get(state, & &1.jumped?), do: "X2-UX81-G1", else: "X1-UX81-G1"
            system = if destination == "X2-UX81-G1", do: "X2-UX81", else: "X1-UX81"

            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: destination, systemSymbol: system)
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 42_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "isComplete" => true, "materials" => []}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X2-UX81-G1", "connections" => ["X1-UX81-G1"]}
            })

          {"/v2/my/ships/FLEET-SHIP/jump", "POST"} ->
            assert conn.body_params == %{"waypointSymbol" => "X2-UX81-G1"}
            Agent.update(state, &%{&1 | jumped?: true})

            Req.Test.json(conn, %{
              "data" => %{
                "nav" => nav_body("IN_ORBIT", destination: "X2-UX81-G1", systemSymbol: "X2-UX81"),
                "cooldown" => %{"shipSymbol" => "FLEET-SHIP", "remainingSeconds" => 60},
                "transaction" => %{"pricePerUnit" => 1_000, "totalPrice" => 1_000},
                "agent" => %{"symbol" => agent.symbol, "credits" => 41_000}
              }
            })
        end
      end)

      assert {:ok, %Intent{status: "completed", last_action_result: evidence}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X2-UX81-G1"
                 }
               )

      assert evidence["kind"] == "jump"
      assert evidence["transaction"]["total_price"] == 1_000
      assert_receive {:request, "/v2/my/ships/FLEET-SHIP/jump", "POST"}
    end

    test "blocks an incomplete jump-gate endpoint without dispatching a jump" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.request_path, conn.method})

        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-G1")
                })
            })

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE"
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"symbol" => "X1-UX81-G1", "isComplete" => false, "materials" => []}
            })
        end
      end)

      assert {:ok, %Intent{status: "blocked", blocker: blocker}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X2-UX81-G1"
                 }
               )

      assert blocker.reason == "jump_gate_incomplete"

      assert blocker.corrective_actions == [
               "inspect_construction",
               "supply_construction",
               "resume"
             ]

      refute_received {:request, "/v2/my/ships/FLEET-SHIP/jump", "POST"}
    end

    test "persists the active Job pause before Navigate dispatches a mutating request" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, {:job_status_at_dispatch, Repo.get!(Job, config.id).status})

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %Intent{status: "waiting", target_waypoint: "X1-UX81-A2"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert_receive {:job_status_at_dispatch, "paused"}
      assert %{status: "paused"} = Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "completes immediately when the Ship is already at the requested Waypoint" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
        })
      end)

      assert {:ok, %Intent{status: "completed"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert Timeline.pending_events(:ship, "FLEET-SHIP") == []
    end

    test "keeps the preempted Job paused after completion" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        assert {"/v2/my/ships/FLEET-SHIP", "GET"} = {conn.request_path, conn.method}

        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
        })
      end)

      assert {:ok, %Intent{status: "completed"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert %{status: "paused", blocked_reason: "Paused by direct navigation"} =
               Fleet.ship_job(agent, "FLEET-SHIP")
    end

    test "orbits a docked Ship before navigating and persists the Intent's arrival" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      arrival = future_iso()
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            send(test_pid, :orbit)
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", arrival, "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert_received :orbit
      assert_received :navigate

      assert [%Event{} = event] = Timeline.pending_events(:ship, "FLEET-SHIP")
      assert event.event_type == "arrival"
      assert event.payload["destination"] == "X1-UX81-A2"
      assert event.payload["intent_id"]
      refute event.payload["job_id"]
    end

    test "waits when an in-transit Ship is already heading to the target" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert [%Event{event_type: "arrival", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "waits through a live cooldown before navigating" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "cooldown" => %{
                    "shipSymbol" => "FLEET-SHIP",
                    "totalSeconds" => 60,
                    "remainingSeconds" => 60,
                    "expiration" => future_iso(60)
                  }
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert [%Event{event_type: "cooldown", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "blocks a fuel-empty Ship without dispatching navigation" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "fuel" => %{"capacity" => 200, "current" => 0}
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "blocked"} = intent} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert intent.blocker.reason == "insufficient_fuel"
      assert "refuel" in intent.blocker.corrective_actions
    end

    test "blocks on an authoritative insufficient-fuel rejection without retrying" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT"),
                  "fuel" => %{"capacity" => 200, "current" => 5}
                })
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            conn
            |> Map.put(:status, 422)
            |> Req.Test.json(%{
              "error" => %{
                "code" => 4203,
                "message" => "Ship does not have enough fuel to travel to destination."
              }
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "blocked"} = intent} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert_received :navigate
      refute_receive :navigate
      assert intent.blocker.reason == "insufficient_fuel"
    end

    test "replaces a pending manual outcome explicitly without cancelling accepted transit" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, first} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert {:error, :intents_reconciliation_required} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A3"
                 }
               )

      intents = Repo.all(from intent in Intent, where: intent.ship_id == ^first.ship_id)
      assert length(intents) == 1

      predecessor = Enum.find(intents, &(&1.id == first.id))
      assert %{status: "waiting", target_waypoint: "X1-UX81-A2"} = predecessor
      refute_received :navigate
    end

    test "refuses Job resume while a manual Navigate is active" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
        extraction_waypoint: "X1-UX81-A2",
        market_waypoint: "X1-UX81-A1",
        cargo_threshold: 30
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert {:error, :intents_active} = Fleet.resume_miner_job(agent, "FLEET-SHIP")
    end

    test "stops an active manual Navigate and keeps the Ship in Manual Control" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      {:ok, config} =
        Fleet.configure_miner_job(agent, "FLEET-SHIP", %{
          extraction_waypoint: "X1-UX81-A2",
          market_waypoint: "X1-UX81-A1",
          cargo_threshold: 30
        })

      Repo.update!(Ecto.Changeset.change(config, status: "active"))

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{"data" => ship_body("FLEET-SHIP")})

          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{
                   waypoint: "X1-UX81-A2"
                 }
               )

      assert [%Intent{id: stop_id, status: "waiting"}] = Intents.current(agent)

      assert {:error, :intents_reconciliation_required} =
               Intents.stop(manual_scope(agent), %Intents.ManualControl{}, stop_id)

      assert [%Intent{}] = Intents.current(agent)

      assert %{status: "paused"} = Fleet.ship_job(agent, "FLEET-SHIP")

      intent = Repo.one!(from i in Intent, select: i.status)
      assert intent == "waiting"
    end

    test "returns an error when the agent has no stored token" do
      agent = agent_fixture("FLEET-NO-TOKEN")
      agent = Repo.update!(Ecto.Changeset.change(agent, agent_token: nil))
      ship_fixture(agent, "FLEET-SHIP")

      assert {:error, :agent_token_missing} =
               Intents.request(
                 manual_scope(agent),
                 agent,
                 %Intents.ManualControl{},
                 "FLEET-SHIP",
                 %Intents.Navigate{waypoint: "X1-UX81-A2"}
               )
    end
  end

  describe "trigger reconciliation" do
    test "arrival revalidation completes the Intent at the requested Waypoint" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      intent =
        Repo.insert!(%Intent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A2",
          system_symbol: "X1-UX81"
        }
      }

      assert {:ok, %Intent{status: "completed"}} =
               Intents.reconcile(agent.id, "FLEET-SHIP", live_ship, :arrival, intent.id, nil)
    end

    test "arrival revalidation navigates on from game truth after arriving elsewhere" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      intent =
        Repo.insert!(%Intent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A3",
          system_symbol: "X1-UX81"
        },
        fuel: %Model.ShipFuel{capacity: 200, current: 100}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP/orbit", "POST"} ->
            Req.Test.json(conn, %{
              "data" => %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A3")}
            })

          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)
            assert conn.body_params["waypointSymbol"] == "X1-UX81-A2"

            Req.Test.json(
              conn,
              %{"data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")}
            )

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.reconcile(agent.id, "FLEET-SHIP", live_ship, :arrival, intent.id, nil)

      assert_received :navigate
    end

    test "ignores events that do not belong to the active Intent" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%Intent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting"
      })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "DOCKED",
          waypoint_symbol: "X1-UX81-A3",
          system_symbol: "X1-UX81"
        }
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        flunk("unexpected request #{conn.request_path}")
      end)

      assert :ok = Intents.reconcile(agent.id, "FLEET-SHIP", live_ship, :arrival, nil, nil)
    end

    test "cooldown revalidation dispatches the pending navigation" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")
      test_pid = self()

      intent =
        Repo.insert!(%Intent{
          ship_id: ship.id,
          type: "navigate",
          target_waypoint: "X1-UX81-A2",
          status: "waiting"
        })

      live_ship = %Model.Ship{
        symbol: "FLEET-SHIP",
        nav: %Model.ShipNav{
          status: "IN_ORBIT",
          waypoint_symbol: "X1-UX81-A1",
          system_symbol: "X1-UX81"
        },
        cooldown: %Model.Cooldown{remaining_seconds: 0},
        fuel: %Model.ShipFuel{capacity: 200, current: 100}
      }

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP/navigate", "POST"} ->
            send(test_pid, :navigate)

            Req.Test.json(conn, %{
              "data" => navigate_response("IN_TRANSIT", future_iso(), "X1-UX81-A2")
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.reconcile(agent.id, "FLEET-SHIP", live_ship, :cooldown, intent.id, nil)

      assert_received :navigate
    end
  end

  describe "boot reconciliation" do
    test "boot recovery confirms an in-flight navigation and re-arms its arrival" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%Intent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{
          "kind" => "navigate",
          "waypoint" => "X1-UX81-A2",
          "expected" => %{"status" => "IN_TRANSIT", "destination" => "X1-UX81-A2"}
        }
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" =>
                    nav_body("IN_TRANSIT", arrival: future_iso(), destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "waiting"}} =
               Intents.reconcile(agent.id, "FLEET-SHIP", nil, :boot, nil, nil)

      assert [%Event{event_type: "arrival", payload: %{"intent_id" => _}}] =
               Timeline.pending_events(:ship, "FLEET-SHIP")
    end

    test "boot recovery completes an Intent whose Ship already sits at the target" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%Intent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "active",
        in_flight_action: %{"kind" => "orbit", "waypoint" => "X1-UX81-A2"}
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")
                })
            })

          {path, _method} ->
            flunk("unexpected request #{path}")
        end
      end)

      assert {:ok, %Intent{status: "completed"}} =
               Intents.reconcile(agent.id, "FLEET-SHIP", nil, :boot, nil, nil)
    end

    test "boot recovery blocks after repeated authoritative read failures" do
      agent = agent_fixture()
      ship = ship_fixture(agent, "FLEET-SHIP")

      Repo.insert!(%Intent{
        ship_id: ship.id,
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "active"
      })

      Req.Test.stub(SpaceTraders.API, fn conn ->
        conn |> Map.put(:status, 500) |> Req.Test.json(%{})
      end)

      assert {:error, :intents_recovery_blocked} =
               Intents.reconcile(agent.id, "FLEET-SHIP", nil, :boot, nil, nil)

      assert [%Intent{status: "blocked", blocker: %JobBlocker{reason: "retry_exhausted"}}] =
               Intents.current(agent)

      intent = Repo.one!(from i in Intent, where: i.ship_id == ^ship.id)
      assert intent.status == "blocked"
      assert intent.blocker.reason == "retry_exhausted"
    end
  end

  defp agent_fixture(symbol \\ "FLEET-2052", operator_id \\ nil) do
    operator_id =
      operator_id ||
        Repo.insert!(%Operator{
          email: "operator-#{System.unique_integer([:positive])}@example.com"
        }).id

    Repo.insert!(%AgentRecord{
      symbol: symbol,
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN",
      operator_id: operator_id
    })
  end

  defp manual_scope(%AgentRecord{operator_id: operator_id}) do
    operator_id
    |> then(&Repo.get!(Operator, &1))
    |> Scope.for_operator()
  end

  defp ship_fixture(agent, symbol) do
    Repo.insert!(%Ship{symbol: symbol, ship_type: "SHIP_COMMAND_FRIGATE", agent_id: agent.id})
  end

  describe "method_selection" do
    test "prefers jump over warp when both are viable" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-A1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })
        end
      end)

      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert selection.selected == "jump"
      assert {"jump", _preview} = List.keyfind!(selection.viable, "jump", 0)
      assert {"warp", _preview} = List.keyfind!(selection.viable, "warp", 0)
      assert selection.rejected == []
    end

    test "falls back to warp when jump gate is incomplete" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-A1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => false,
                "materials" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })
        end
      end)

      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert selection.selected == "warp"
      assert {"warp", _preview} = List.keyfind!(selection.viable, "warp", 0)
      assert {"jump", reason} = List.keyfind!(selection.rejected, "jump", 0)
      assert {:jump_gate_incomplete, "X1-UX81-G1"} = reason
    end

    test "returns only jump when warp drive is missing" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I"}],
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-G1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })
        end
      end)

      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert selection.selected == "jump"
      assert {"jump", _preview} = List.keyfind!(selection.viable, "jump", 0)
      assert {"warp", :warp_drive_missing} = List.keyfind!(selection.rejected, "warp", 0)
    end

    test "restricts to only warp when allowed_methods excludes jump" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_WARP_DRIVE_I", "range" => 30}],
                  "fuel" => %{"capacity" => 200, "current" => 150},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-G1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})
        end
      end)

      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1",
                 allowed_methods: ["warp"]
               )

      assert selection.selected == "warp"
      assert {"warp", _preview} = List.keyfind!(selection.viable, "warp", 0)
      assert {"jump", :method_not_allowed} = List.keyfind!(selection.rejected, "jump", 0)
      assert selection.allowed_methods == ["warp"]
    end

    test "returns no viable methods when both jump and warp fail" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.request_path, conn.method} do
          {"/v2/my/ships/FLEET-SHIP", "GET"} ->
            Req.Test.json(conn, %{
              "data" =>
                ship_body("FLEET-SHIP", %{
                  "modules" => [%{"symbol" => "MODULE_CARGO_HOLD_I"}],
                  "fuel" => %{"capacity" => 200, "current" => 0},
                  "nav" => %{
                    "systemSymbol" => "X1-UX81",
                    "waypointSymbol" => "X1-UX81-G1",
                    "status" => "IN_ORBIT",
                    "flightMode" => "CRUISE"
                  }
                })
            })

          {"/v2/my/agent", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"credits" => 2_000}})

          {"/v2/systems/X1-UX81/waypoints", "GET"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-G1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "JUMP_GATE",
                  "x" => 0,
                  "y" => 0
                }
              ]
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1", "GET"} ->
            Req.Test.json(conn, %{"data" => %{"symbol" => "X1-UX81-G1", "x" => 0, "y" => 0}})

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-G1",
                "isComplete" => false,
                "materials" => []
              }
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X2-UX81-G1"]}
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/construction", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X2-UX81-G1",
                "isComplete" => true,
                "materials" => []
              }
            })

          {"/v2/systems/X2-UX81/waypoints/X2-UX81-G1/jump-gate", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{"connections" => ["X1-UX81-G1"]}
            })

          {"/v2/systems/X1-UX81/waypoints/X1-UX81-G1/market", "GET"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "tradeGoods" => [%{"symbol" => "ANTIMATTER", "purchasePrice" => 1_000}]
              }
            })
        end
      end)

      assert {:ok, selection} =
               Intents.method_selection(agent, "FLEET-SHIP", "X2-UX81-G1")

      assert selection.selected == nil
      assert selection.viable == []
      assert length(selection.rejected) == 2
    end

    test "returns same_system_route for same-system targets" do
      agent = agent_fixture()
      ship_fixture(agent, "FLEET-SHIP")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{
          "data" =>
            ship_body("FLEET-SHIP", %{
              "nav" => %{
                "systemSymbol" => "X1-UX81",
                "waypointSymbol" => "X1-UX81-A1",
                "status" => "IN_ORBIT",
                "flightMode" => "CRUISE"
              }
            })
        })
      end)

      assert {:error, :same_system_route} =
               Intents.method_selection(agent, "FLEET-SHIP", "X1-UX81-A2")
    end
  end
end
