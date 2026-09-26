defmodule SpaceTraders.FleetTransferTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetConstruction
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.API.Model.Ship, as: LiveShip
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  test "transfer waits for authoritative Cargo on both claimed Ships" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, _} = Fleet.record_ship(agent, "PRODUCER", "SHIP_COMMAND_FRIGATE")
    {:ok, _} = Fleet.record_ship(agent, "HAULER", "SHIP_COMMAND_FRIGATE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Complete construction"}]},
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

    producer = %PortfolioCandidate{
      id: "producer",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["PRODUCER"],
      reservations: %{},
      pledges: [
        %{
          outcome: {:cargo_transfer, "PRODUCER", "HAULER", "IRON_ORE"},
          amount: 4,
          backing: {:claim, "PRODUCER"}
        }
      ],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    hauler = %PortfolioCandidate{
      id: "hauler",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["HAULER"],
      reservations: %{"cargo_capacity:HAULER" => 4},
      pledges: [
        %{
          outcome: {:construction, "X1-UX81-A1", "IRON_ORE"},
          amount: 4,
          backing: {:dependency, "cargo"}
        }
      ],
      dependencies: [%{id: "cargo", kind: :acquisition, candidate_id: "producer", amount: 4}],
      expected_value: 2,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [hauler, producer], %{
        as_of: DateTime.utc_now(),
        claims: ["PRODUCER", "HAULER"],
        reservations: %{"cargo_capacity:HAULER" => 40},
        outcome_remaining: %{{:construction, "X1-UX81-A1", "IRON_ORE"} => 4}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "transfer-v1"
      })

    source = Enum.find(portfolio.commitments, &(&1.candidate_id == "producer"))
    target = Enum.find(portfolio.commitments, &(&1.candidate_id == "hauler"))

    {:ok, count} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, target_visible} = Elixir.Agent.start_link(fn -> false end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      cargo = fn units ->
        %{
          "capacity" => 40,
          "units" => units,
          "inventory" =>
            if(units > 0,
              do: [
                %{
                  "symbol" => "IRON_ORE",
                  "name" => "Iron Ore",
                  "description" => "Ore",
                  "units" => units
                }
              ],
              else: []
            )
        }
      end

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships/PRODUCER"} ->
          transferred = Elixir.Agent.get(count, & &1) > 0

          Req.Test.json(conn, %{
            "data" =>
              ship_body("PRODUCER", %{"cargo" => cargo.(if(transferred, do: 8, else: 12))})
          })

        {"GET", "/v2/my/ships/HAULER"} ->
          transferred = Elixir.Agent.get(target_visible, & &1)

          Req.Test.json(conn, %{
            "data" => ship_body("HAULER", %{"cargo" => cargo.(if(transferred, do: 4, else: 0))})
          })

        {"POST", "/v2/my/ships/PRODUCER/transfer"} ->
          assert Jason.decode!(conn.body_params |> Jason.encode!()) == %{
                   "shipSymbol" => "HAULER",
                   "tradeSymbol" => "IRON_ORE",
                   "units" => 4
                 }

          Elixir.Agent.update(count, &(&1 + 1))
          Req.Test.json(conn, %{"data" => %{"cargo" => cargo.(8)}})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => true,
              "materials" => [%{"tradeSymbol" => "IRON_ORE", "required" => 4, "fulfilled" => 4}]
            }
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => []})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        other ->
          flunk("unexpected request: #{inspect(other)}")
      end
    end)

    assert {:ok, %Intent{status: "blocked"} = unresolved} =
             Intents.request_commitment_transfer(agent, source, target, portfolio, %{
               source_ship: "PRODUCER",
               target_ship: "HAULER",
               trade_symbol: "IRON_ORE",
               units: 4,
               delivery: %{
                 type: "construction",
                 system: "X1-UX81",
                 waypoint: "X1-UX81-A1",
                 trade_symbol: "IRON_ORE"
               }
             })

    assert Elixir.Agent.get(count, & &1) == 1

    Elixir.Agent.update(target_visible, fn _ -> true end)

    assert {:ok, %Intent{status: "completed", last_action_result: %{"units" => 4}} = transfer} =
             Intents.advance(
               agent,
               unresolved,
               LiveShip.from_json(
                 ship_body("PRODUCER", %{
                   "cargo" => %{
                     "capacity" => 40,
                     "units" => 8,
                     "inventory" => [
                       %{
                         "symbol" => "IRON_ORE",
                         "name" => "Iron Ore",
                         "description" => "Ore",
                         "units" => 8
                       }
                     ]
                   }
                 })
               )
             )

    assert Elixir.Agent.get(count, & &1) == 1

    assert {:ok, _} = FleetExecution.continue_after_intent(agent, source, portfolio, transfer)

    assert %Intent{status: "completed", last_action_result: %{"external_completion" => true}} =
             Repo.get_by!(Intent, fleet_commitment_id: target.id, type: "deliver")
  end

  test "Construction reconciliation publishes and executes a producer-hauler pair" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, _} = Fleet.record_ship(agent, "PRODUCER", "SHIP_COMMAND_FRIGATE")
    {:ok, _} = Fleet.record_ship(agent, "HAULER", "SHIP_COMMAND_FRIGATE")
    {:ok, unrelated_ship} = Fleet.record_ship(agent, "UNRELATED", "SHIP_PROBE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Complete construction"}],
          "hard_constraints" => []
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

    unrelated = %PortfolioCandidate{
      id: "independent",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["UNRELATED"],
      reservations: %{credits: 100},
      pledges: [
        %{
          outcome: {:construction, "X1-UX81-A3", "COPPER"},
          amount: 1,
          backing: {:claim, "UNRELATED"}
        }
      ],
      dependencies: [%{subject: "construction:X1-UX81:X1-UX81-A3", state: :satisfied}],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [unrelated], %{
        as_of: DateTime.utc_now(),
        claims: ["UNRELATED"],
        reservations: %{credits: 1000}
      })

    {:ok, current} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selection,
        %{evidence_references: [], expectations: %{}, calibration_version: "independent-v1"}
      )

    [independent] = current.commitments

    running =
      Repo.insert!(%Intent{
        ship_id: unrelated_ship.id,
        caller: "commitment",
        fleet_commitment_id: independent.id,
        fleet_commitment_portfolio_id: current.id,
        fleet_commitment_portfolio_version: current.version,
        type: "navigate",
        status: "waiting",
        target_waypoint: "X1-UX81-A2"
      })

    Repo.insert!(%SpaceTraders.Evidence.Observation{
      agent_id: agent.id,
      subject: "construction:X1-UX81:X1-UX81-A1",
      operation_id: "get-construction",
      dependency_keys: [],
      facts: %{"is_complete" => false},
      response_fingerprint: "known-project",
      observed_at: DateTime.utc_now()
    })

    Repo.insert!(%SpaceTraders.Evidence.Observation{
      agent_id: agent.id,
      subject: "construction:X1-UX81:X1-UX81-A3",
      operation_id: "get-construction",
      dependency_keys: [],
      facts: %{"is_complete" => false},
      response_fingerprint: "independent-project",
      observed_at: DateTime.utc_now()
    })

    {:ok, moves} = Elixir.Agent.start_link(fn -> 0 end)
    {:ok, fail_first_read} = Elixir.Agent.start_link(fn -> true end)

    cargo = fn units ->
      %{
        "capacity" => 40,
        "units" => units,
        "inventory" =>
          if(units > 0,
            do: [
              %{
                "symbol" => "IRON_ORE",
                "name" => "Iron Ore",
                "description" => "Ore",
                "units" => units
              }
            ],
            else: []
          )
      }
    end

    Req.Test.stub(SpaceTraders.API, fn conn ->
      transferred = Elixir.Agent.get(moves, & &1) > 0

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body("PRODUCER", %{"cargo" => cargo.(if(transferred, do: 8, else: 12))}),
              ship_body("HAULER", %{"cargo" => cargo.(if(transferred, do: 4, else: 0))}),
              ship_body("UNRELATED", %{"cargo" => cargo.(0)})
            ]
          })

        {"GET", "/v2/my/ships/PRODUCER"} ->
          if Elixir.Agent.get_and_update(fail_first_read, &{&1, false}) do
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              400,
              Jason.encode!(%{"error" => %{"code" => 500, "message" => "unavailable"}})
            )
          else
            Req.Test.json(conn, %{
              "data" =>
                ship_body("PRODUCER", %{"cargo" => cargo.(if(transferred, do: 8, else: 12))})
            })
          end

        {"GET", "/v2/my/ships/HAULER"} ->
          Req.Test.json(conn, %{
            "data" => ship_body("HAULER", %{"cargo" => cargo.(if(transferred, do: 4, else: 0))})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => transferred,
              "materials" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "required" => 4,
                  "fulfilled" => if(transferred, do: 4, else: 0)
                }
              ]
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A3/construction"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A3",
              "isComplete" => false,
              "materials" => [%{"tradeSymbol" => "COPPER", "required" => 1, "fulfilled" => 0}]
            }
          })

        {"POST", "/v2/my/ships/PRODUCER/transfer"} ->
          Elixir.Agent.update(moves, &(&1 + 1))
          Req.Test.json(conn, %{"data" => %{"cargo" => cargo.(8)}})

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:error, _} =
             FleetConstruction.reconcile(Scope.for_operator(operator), agent, revision)

    assert Repo.get_by(Intent, type: "transfer") == nil

    assert {:ok, result} =
             FleetConstruction.reconcile(Scope.for_operator(operator), agent, revision)

    assert Elixir.Agent.get(moves, & &1) == 1, inspect(result)

    assert Repo.aggregate(Commitment, :count) == 3

    assert Repo.get_by!(Intent, type: "transfer").status == "completed"
    assert Repo.get_by!(Intent, type: "deliver").last_action_result["external_completion"] == true
    assert Repo.get!(Intent, running.id).status == "waiting"

    assert {:ok, %{commitment_id: independent_id}} =
             FleetAllocation.current_ship_claim(agent, "UNRELATED")

    assert independent_id == independent.id
  end

  test "Contract reconciliation transfers to a claimed hauler before delivery and fulfillment" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, _} = Fleet.record_ship(agent, "PRODUCER", "SHIP_COMMAND_FRIGATE")
    {:ok, _} = Fleet.record_ship(agent, "HAULER", "SHIP_COMMAND_FRIGATE")
    {:ok, unrelated_ship} = Fleet.record_ship(agent, "UNRELATED", "SHIP_PROBE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Fulfil contracts"}],
          "hard_constraints" => []
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

    independent = %PortfolioCandidate{
      id: "other-contract",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: ["UNRELATED"],
      reservations: %{credits: 100},
      pledges: [
        %{
          outcome: {:contract, "ctr-2", "X1-UX81-A3", "COPPER"},
          amount: 1,
          backing: {:claim, "UNRELATED"}
        }
      ],
      dependencies: [%{subject: "contracts:ctr-2", state: :satisfied}],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selected} =
      FleetAllocation.select_portfolio(revision, [independent], %{
        as_of: DateTime.utc_now(),
        claims: ["UNRELATED"],
        reservations: %{credits: 1000}
      })

    {:ok, original} =
      FleetAllocation.publish_portfolio(
        Scope.for_operator(operator),
        generation.id,
        selected,
        %{evidence_references: [], expectations: %{}, calibration_version: "contracts-v1"}
      )

    [retained] = original.commitments

    running =
      Repo.insert!(%Intent{
        ship_id: unrelated_ship.id,
        caller: "commitment",
        fleet_commitment_id: retained.id,
        fleet_commitment_portfolio_id: original.id,
        fleet_commitment_portfolio_version: original.version,
        type: "navigate",
        status: "waiting",
        target_waypoint: "X1-UX81-A3"
      })

    {:ok, state} = Elixir.Agent.start_link(fn -> :outstanding end)
    {:ok, fail_first_read} = Elixir.Agent.start_link(fn -> true end)

    cargo = fn units ->
      %{
        "capacity" => 40,
        "units" => units,
        "inventory" =>
          if(units > 0,
            do: [
              %{
                "symbol" => "IRON_ORE",
                "name" => "Iron Ore",
                "description" => "Ore",
                "units" => units
              }
            ],
            else: []
          )
      }
    end

    Req.Test.stub(SpaceTraders.API, fn conn ->
      phase = Elixir.Agent.get(state, & &1)
      transferred = phase != :outstanding

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/contracts"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => phase == :fulfilled,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A1",
                      "unitsRequired" => 4,
                      "unitsFulfilled" => if(phase in [:delivered, :fulfilled], do: 4, else: 0)
                    }
                  ],
                  "payment" => %{"onAccepted" => 0, "onFulfilled" => 100}
                }
              },
              %{
                "id" => "ctr-2",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "COPPER",
                      "destinationSymbol" => "X1-UX81-A3",
                      "unitsRequired" => 1,
                      "unitsFulfilled" => 0
                    }
                  ],
                  "payment" => %{}
                }
              }
            ]
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body("PRODUCER", %{"cargo" => cargo.(if(transferred, do: 8, else: 12))}),
              ship_body("HAULER", %{"cargo" => cargo.(if(phase == :transferred, do: 4, else: 0))}),
              ship_body("UNRELATED", %{"cargo" => cargo.(0)})
            ]
          })

        {"GET", "/v2/my/ships/PRODUCER"} ->
          if Elixir.Agent.get_and_update(fail_first_read, &{&1, false}) do
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(
              400,
              Jason.encode!(%{"error" => %{"code" => 500, "message" => "unavailable"}})
            )
          else
            Req.Test.json(conn, %{
              "data" =>
                ship_body("PRODUCER", %{"cargo" => cargo.(if(transferred, do: 8, else: 12))})
            })
          end

        {"GET", "/v2/my/ships/HAULER"} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body("HAULER", %{"cargo" => cargo.(if(phase == :transferred, do: 4, else: 0))})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        {"POST", "/v2/my/ships/PRODUCER/transfer"} ->
          assert phase == :outstanding
          Elixir.Agent.update(state, fn _ -> :transferred end)
          Req.Test.json(conn, %{"data" => %{"cargo" => cargo.(8)}})

        {"POST", "/v2/my/contracts/ctr-1/deliver"} ->
          assert phase == :transferred
          Elixir.Agent.update(state, fn _ -> :delivered end)

          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => cargo.(0),
              "contract" => %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A1",
                      "unitsRequired" => 4,
                      "unitsFulfilled" => 4
                    }
                  ],
                  "payment" => %{}
                }
              }
            }
          })

        {"POST", "/v2/my/contracts/ctr-1/fulfill"} ->
          assert phase == :delivered
          Elixir.Agent.update(state, fn _ -> :fulfilled end)

          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{},
              "contract" => %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => true,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [],
                  "payment" => %{}
                }
              }
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:error, _} = FleetContracts.reconcile(Scope.for_operator(operator), agent, revision)
    assert Repo.get_by(Intent, type: "transfer") == nil

    assert {:ok, %{fulfilled: true}} =
             FleetContracts.reconcile(Scope.for_operator(operator), agent, revision)

    assert Elixir.Agent.get(state, & &1) == :fulfilled
    assert Repo.aggregate(Commitment, :count) == 3
    assert Repo.get_by!(Intent, type: "transfer").status == "completed"
    assert Repo.get_by!(Intent, type: "deliver").status == "completed"
    assert Repo.get!(Intent, running.id).status == "waiting"

    assert {:ok, %{commitment_id: retained_id}} =
             FleetAllocation.current_ship_claim(agent, "UNRELATED")

    assert retained_id == retained.id
  end

  test "a refinery produces Construction material before the hauler transfers and delivers it" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, _} = Fleet.record_ship(agent, "REFINER", "SHIP_COMMAND_FRIGATE")
    {:ok, _} = Fleet.record_ship(agent, "HAULER", "SHIP_COMMAND_FRIGATE")

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{
          "objectives" => [%{"objective" => "Complete construction"}],
          "hard_constraints" => []
        },
        source: "operator",
        activated_at: DateTime.utc_now(:second)
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

    Repo.insert!(%SpaceTraders.Evidence.Observation{
      agent_id: agent.id,
      subject: "construction:X1-UX81:X1-UX81-A1",
      operation_id: "get-construction",
      dependency_keys: [],
      facts: %{"is_complete" => false},
      response_fingerprint: "known-project",
      observed_at: DateTime.utc_now()
    })

    {:ok, phase} = Elixir.Agent.start_link(fn -> :ore end)
    test_pid = self()

    cargo = fn symbol, units ->
      %{
        "capacity" => 200,
        "units" => units,
        "inventory" => if(units > 0, do: [%{"symbol" => symbol, "units" => units}], else: [])
      }
    end

    Req.Test.stub(SpaceTraders.API, fn conn ->
      current = Elixir.Agent.get(phase, & &1)
      send(test_pid, {conn.method, conn.request_path})

      refiner_cargo =
        case current do
          :ore -> cargo.("IRON_ORE", 100)
          :refined -> cargo.("IRON", 10)
          _ -> cargo.("IRON", 7)
        end

      hauler_cargo = if current == :transferred, do: cargo.("IRON", 3), else: cargo.("IRON", 0)

      refiner =
        ship_body("REFINER", %{
          "nav" => nav_body("IN_ORBIT"),
          "modules" => [%{"symbol" => "MODULE_ORE_REFINERY_I"}],
          "cargo" => refiner_cargo
        })

      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [refiner, ship_body("HAULER", %{"cargo" => hauler_cargo})]
          })

        {"GET", "/v2/my/ships/REFINER"} ->
          Req.Test.json(conn, %{"data" => refiner})

        {"GET", "/v2/my/ships/HAULER"} ->
          Req.Test.json(conn, %{"data" => ship_body("HAULER", %{"cargo" => hauler_cargo})})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => agent.faction
            }
          })

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A1",
              "isComplete" => current == :delivered,
              "materials" => [
                %{
                  "tradeSymbol" => "IRON",
                  "required" => 3,
                  "fulfilled" => if(current == :delivered, do: 3, else: 0)
                }
              ]
            }
          })

        {"POST", "/v2/my/ships/REFINER/refine"} ->
          assert current == :ore
          Elixir.Agent.update(phase, fn _ -> :refined end)

          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => cargo.("IRON", 10),
              "cooldown" => %{
                "shipSymbol" => "REFINER",
                "remainingSeconds" => 0,
                "totalSeconds" => 0,
                "expiration" => DateTime.utc_now() |> DateTime.to_iso8601()
              },
              "produced" => [%{"tradeSymbol" => "IRON", "units" => 10}],
              "consumed" => [%{"tradeSymbol" => "IRON_ORE", "units" => 100}]
            }
          })

        {"POST", "/v2/my/ships/REFINER/transfer"} ->
          assert current == :refined
          Elixir.Agent.update(phase, fn _ -> :transferred end)
          Req.Test.json(conn, %{"data" => %{"cargo" => cargo.("IRON", 7)}})

        {"POST", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply"} ->
          assert current == :transferred
          Elixir.Agent.update(phase, fn _ -> :delivered end)

          Req.Test.json(conn, %{
            "data" => %{
              "cargo" => cargo.("IRON", 0),
              "construction" => %{
                "symbol" => "X1-UX81-A1",
                "isComplete" => true,
                "materials" => [%{"tradeSymbol" => "IRON", "required" => 3, "fulfilled" => 3}]
              }
            }
          })

        other ->
          flunk("unexpected game request: #{inspect(other)}")
      end
    end)

    assert {:ok, _} = FleetConstruction.reconcile(Scope.for_operator(operator), agent, revision)
    assert Elixir.Agent.get(phase, & &1) == :delivered
    assert_receive {"POST", "/v2/my/ships/REFINER/refine"}
    assert_receive {"POST", "/v2/my/ships/REFINER/transfer"}
    assert_receive {"POST", "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/construction/supply"}
    assert Repo.get_by!(Intent, type: "acquire_resources").status == "completed"
    assert Repo.get_by!(Intent, type: "transfer").status == "completed"
    assert Repo.get_by!(Intent, type: "deliver").status == "completed"
  end
end
