defmodule SpaceTraders.IntentsTest do
  use SpaceTraders.DataCase, async: true

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
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
               agent,
               %Intents.ManualControl{},
               "INTENTS-DELIVER-SHIP",
               %Intents.DeliverGoods{
                 contract_id: "INTENTS-CONTRACT",
                 destination: "X1-UX81-A1",
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
               agent,
               %Intents.ManualControl{},
               "INTENTS-INSTALL-SHIP",
               %Intents.InstallModule{module_symbol: "MODULE_CARGO_HOLD_I"}
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
