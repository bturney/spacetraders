defmodule SpaceTraders.ContractExecutionTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Fleet.Intents
  alias SpaceTraders.FleetAllocation.{Commitment, Portfolio}
  alias SpaceTraders.FleetContracts
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.API.Model.Ship, as: LiveShip
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.API.OperationInventory

  import SpaceTraders.ShipBody

  test "a Contract delivery cannot start without the current matching Ship Claim" do
    agent = agent_fixture(operator_fixture())
    commitment = %Commitment{id: 123, claims: ["SHIP-1"]}
    portfolio = %Portfolio{id: 456, version: 1}

    delivery = %{
      contract_id: "ctr-1",
      destination_waypoint: "X1-A2",
      trade_symbol: "IRON_ORE",
      units: 5
    }

    assert {:error, :no_current_ship_claim} =
             Intents.request_commitment_contract_delivery(
               agent,
               commitment,
               portfolio,
               "SHIP-1",
               delivery
             )
  end

  test "an unproven purchase quantity cannot become a Contract delivery" do
    agent = agent_fixture(operator_fixture())

    assert {:error, :invalid_purchase_evidence} =
             FleetExecution.continue_after_intent(
               agent,
               %Commitment{id: 1, claims: ["SHIP-1"]},
               %Portfolio{id: 2, version: 1},
               %{
                 type: "buy",
                 status: "completed",
                 last_action_result: %{"units" => nil},
                 parameters: %{
                   "market_trade" => %{
                     "contract_id" => "ctr-1",
                     "destination_waypoint" => "X1-A2",
                     "trade_symbol" => "IRON_ORE"
                   }
                 }
               }
             )
  end

  test "fulfillment reads authoritative Contract state and never treats delivered goods as fulfilled" do
    agent = agent_fixture(operator_fixture())

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => []
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/contracts"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => true,
            "fulfilled" => false,
            "terms" => %{
              "deadline" => "2099-01-01T00:00:00Z",
              "deliver" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "destinationSymbol" => "X1-A2",
                  "unitsRequired" => 5,
                  "unitsFulfilled" => 4
                }
              ],
              "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
            }
          }
        ]
      })
    end)

    assert {:error, :delivery_remaining} =
             FleetContracts.fulfill_if_ready(agent, revision, "ctr-1")
  end

  test "completion waits for the game's fulfilled flag after calling fulfill" do
    agent = agent_fixture(operator_fixture())

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => []
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/contracts"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-A2",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => 5
                    }
                  ],
                  "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
                }
              }
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => "COSMIC"
            }
          })

        {"POST", "/v2/my/contracts/ctr-1/fulfill"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "agent" => %{},
              "contract" => %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [],
                  "payment" => %{}
                }
              }
            }
          })

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    assert {:error, :fulfillment_unconfirmed} =
             FleetContracts.fulfill_if_ready(agent, revision, "ctr-1")
  end

  test "a fulfilled Contract remains completed after reconciliation without a second fulfill" do
    agent = agent_fixture(operator_fixture())

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("fulfill-contract"),
        "/my/contracts/ctr-1/fulfill",
        agent_id: agent.id
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :ambiguous, %{reason: "timeout"})

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => []
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/contracts"} ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => true,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [],
                  "payment" => %{}
                }
              }
            ]
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => "COSMIC"
            }
          })

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    assert {:ok, %{fulfilled: true}} = FleetContracts.fulfill_if_ready(agent, revision, "ctr-1")
    assert MutationAttempts.get!(attempt.id).state == "accepted"
    assert {:ok, %{fulfilled: true}} = FleetContracts.fulfill_if_ready(agent, revision, "ctr-1")
  end

  test "an ambiguous acceptance is reconciled from Contract state before attempting another mutation" do
    agent = agent_fixture(operator_fixture())

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("accept-contract"),
        "/my/contracts/ctr-1/accept",
        agent_id: agent.id
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :ambiguous, %{reason: "timeout"})

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => []
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/contracts" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [],
                  "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
                }
              }
            ]
          })

        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => "COSMIC"
            }
          })

        path ->
          flunk("unexpected mutation: #{path}")
      end
    end)

    assert {:ok, :already_accepted} =
             FleetContracts.accept_if_admissible(agent, revision, "ctr-1", %{
               as_of: DateTime.utc_now(),
               credits: 1000,
               worst_case_cost: 100,
               estimated_seconds: 3600,
               evidence_id: "offer-1"
             })

    assert MutationAttempts.get!(attempt.id).state == "accepted"
  end

  test "acceptance uses live credits, not a stale planning estimate, to enforce the credit floor" do
    agent = agent_fixture(operator_fixture())

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => ["Keep at least 500 credits available"]
      }
    }

    now = DateTime.utc_now()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/contracts" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => false,
                "fulfilled" => false,
                "deadlineToAccept" => DateTime.add(now, 3600, :second) |> DateTime.to_iso8601(),
                "terms" => %{
                  "deadline" => DateTime.add(now, 86_400, :second) |> DateTime.to_iso8601(),
                  "deliver" => [],
                  "payment" => %{"onAccepted" => 0, "onFulfilled" => 200}
                }
              }
            ]
          })

        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 400,
              "headquarters" => agent.headquarters,
              "startingFaction" => "COSMIC"
            }
          })

        path ->
          flunk("unexpected mutation: #{path}")
      end
    end)

    assert {:error, :hard_constraint} =
             FleetContracts.accept_if_admissible(agent, revision, "ctr-1", %{
               as_of: now,
               credits: 10_000,
               worst_case_cost: 50,
               estimated_seconds: 3600,
               evidence_id: "offer-1"
             })
  end

  test "negotiation cannot be repeated while an offered Contract remains pending" do
    agent = agent_fixture(operator_fixture())

    revision = %Revision{
      id: 42,
      document: %{
        "objectives" => [%{"objective" => "Fulfil contracts"}],
        "hard_constraints" => []
      }
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/contracts"

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => false,
            "fulfilled" => false,
            "deadlineToAccept" => "2099-01-01T00:00:00Z",
            "terms" => %{"deadline" => "2099-01-02T00:00:00Z", "deliver" => [], "payment" => %{}}
          }
        ]
      })
    end)

    assert {:error, :offer_pending} =
             FleetContracts.negotiate_if_available(agent, revision, "SHIP-1")
  end

  test "another Agent completing a deliverable completes claimed delivery without a mutation" do
    {agent, ship, portfolio, commitment} = claimed_contract_ship()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/ships/CONTRACT-SHIP" ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A2")})
          })

        "/v2/my/contracts" ->
          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A2",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => 5
                    }
                  ],
                  "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
                }
              }
            ]
          })

        path ->
          flunk("unexpected gameplay request: #{path}")
      end
    end)

    assert {:ok, %{status: "completed", last_action_result: %{"units" => 0}}} =
             Intents.request_commitment_contract_delivery(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               %{
                 contract_id: "ctr-1",
                 destination_waypoint: "X1-UX81-A2",
                 trade_symbol: "IRON_ORE",
                 units: 5
               }
             )
  end

  test "an ambiguous delivery resolves to external completion only from authoritative fulfillment" do
    {agent, ship, portfolio, commitment} = claimed_contract_ship()

    intent =
      Repo.insert!(%Intent{
        caller: "commitment",
        type: "deliver",
        status: "blocked",
        ship_id: ship.id,
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        target_waypoint: "X1-UX81-A2",
        parameters: %{
          "trade_symbol" => "IRON_ORE",
          "units" => 1,
          "recipient" => %{
            "type" => "contract",
            "contract_id" => "ctr-1",
            "waypoint" => "X1-UX81-A2"
          }
        },
        in_flight_action: %{
          "kind" => "deliver",
          "trade_symbol" => "IRON_ORE",
          "units" => 1,
          "fulfilled_before" => 4,
          "cargo_before" => 12,
          "recipient" => %{
            "type" => "contract",
            "contract_id" => "ctr-1",
            "waypoint" => "X1-UX81-A2"
          }
        }
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/contracts"}

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => true,
            "fulfilled" => true,
            "terms" => %{
              "deadline" => "2099-01-01T00:00:00Z",
              "deliver" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "destinationSymbol" => "X1-UX81-A2",
                  "unitsRequired" => 5,
                  "unitsFulfilled" => 5
                }
              ],
              "payment" => %{}
            }
          }
        ]
      })
    end)

    live_ship =
      LiveShip.from_json(
        ship_body(ship.symbol, %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A2")})
      )

    assert {:ok, %{status: "completed", last_action_result: %{"external_completion" => true}}} =
             Intents.advance(agent, intent, live_ship)
  end

  test "an ambiguous claimed delivery settles its mutation attempt from Cargo and Contract evidence" do
    {agent, ship, portfolio, commitment} = claimed_contract_ship()
    recipient = %{"type" => "contract", "contract_id" => "ctr-1", "waypoint" => "X1-UX81-A2"}

    action = %{
      "kind" => "deliver",
      "trade_symbol" => "IRON_ORE",
      "units" => 1,
      "fulfilled_before" => 4,
      "cargo_before" => 12,
      "recipient" => recipient
    }

    intent =
      Repo.insert!(%Intent{
        caller: "commitment",
        type: "deliver",
        status: "blocked",
        ship_id: ship.id,
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        target_waypoint: "X1-UX81-A2",
        parameters: %{"trade_symbol" => "IRON_ORE", "units" => 1, "recipient" => recipient},
        in_flight_action: action
      })

    {:ok, attempt} =
      MutationAttempts.prepare(
        OperationInventory.fetch!("deliver-contract"),
        "/my/contracts/ctr-1/deliver",
        agent_id: agent.id,
        json: %{"shipSymbol" => ship.symbol, "tradeSymbol" => "IRON_ORE", "units" => 1}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, _} = MutationAttempts.record_outcome(attempt, :ambiguous, %{reason: "timeout"})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/contracts"}

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => true,
            "fulfilled" => false,
            "terms" => %{
              "deadline" => "2099-01-01T00:00:00Z",
              "deliver" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "destinationSymbol" => "X1-UX81-A2",
                  "unitsRequired" => 5,
                  "unitsFulfilled" => 5
                }
              ],
              "payment" => %{}
            }
          }
        ]
      })
    end)

    live_ship =
      LiveShip.from_json(
        ship_body(ship.symbol, %{
          "nav" => nav_body("DOCKED", destination: "X1-UX81-A2"),
          "cargo" => %{
            "capacity" => 40,
            "units" => 11,
            "inventory" => [%{"symbol" => "IRON_ORE", "units" => 11}]
          }
        })
      )

    assert {:ok, %{status: "completed"}} = Intents.advance(agent, intent, live_ship)
    assert MutationAttempts.get!(attempt.id).state == "accepted"
  end

  test "a claimed Contract buy skips purchase when authoritative delivery is already complete" do
    {agent, ship, portfolio, commitment} = claimed_contract_ship()

    intent =
      Repo.insert!(%Intent{
        caller: "commitment",
        type: "buy",
        status: "active",
        ship_id: ship.id,
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version,
        target_waypoint: "X1-UX81-A2",
        parameters: %{
          "trade_symbol" => "IRON_ORE",
          "units" => 5,
          "max_price" => 10,
          "market_trade" => %{
            "contract_id" => "ctr-1",
            "source_waypoint" => "X1-UX81-A2",
            "destination_waypoint" => "X1-UX81-A2",
            "trade_symbol" => "IRON_ORE"
          }
        }
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {conn.method, conn.request_path} == {"GET", "/v2/my/contracts"}

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => true,
            "fulfilled" => false,
            "terms" => %{
              "deadline" => "2099-01-01T00:00:00Z",
              "deliver" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "destinationSymbol" => "X1-UX81-A2",
                  "unitsRequired" => 5,
                  "unitsFulfilled" => 5
                }
              ],
              "payment" => %{}
            }
          }
        ]
      })
    end)

    live_ship =
      LiveShip.from_json(
        ship_body(ship.symbol, %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A2")})
      )

    assert {:ok, %{status: "completed", last_action_result: %{"units" => 0}}} =
             Intents.advance(agent, intent, live_ship)
  end

  test "the Fleet delivers claimed Cargo and completes only after authoritative fulfillment" do
    {agent, ship, _portfolio, _commitment} = claimed_contract_ship()
    operator = Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id)
    generation = Repo.get_by!(Generation, agent_id: agent.id)
    revision = Repo.get!(Revision, generation.fleet_strategy_revision_id)
    {:ok, game_state} = Elixir.Agent.start_link(fn -> :outstanding end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/contracts"} ->
          fulfilled = if Elixir.Agent.get(game_state, & &1) == :outstanding, do: 4, else: 5

          Req.Test.json(conn, %{
            "data" => [
              %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => Elixir.Agent.get(game_state, & &1) == :fulfilled,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A2",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => fulfilled
                    }
                  ],
                  "payment" => %{"onAccepted" => 100, "onFulfilled" => 200}
                }
              }
            ]
          })

        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{
            "data" => [
              ship_body(ship.symbol, %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A2")})
            ]
          })

        {"GET", "/v2/my/ships/CONTRACT-SHIP"} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{"nav" => nav_body("DOCKED", destination: "X1-UX81-A2")})
          })

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "credits" => 1000,
              "headquarters" => agent.headquarters,
              "startingFaction" => "COSMIC"
            }
          })

        {"POST", "/v2/my/contracts/ctr-1/deliver"} ->
          Elixir.Agent.update(game_state, fn _ -> :delivered end)

          Req.Test.json(conn, %{
            "data" => %{
              "contract" => %{
                "id" => "ctr-1",
                "accepted" => true,
                "fulfilled" => false,
                "terms" => %{
                  "deadline" => "2099-01-01T00:00:00Z",
                  "deliver" => [
                    %{
                      "tradeSymbol" => "IRON_ORE",
                      "destinationSymbol" => "X1-UX81-A2",
                      "unitsRequired" => 5,
                      "unitsFulfilled" => 5
                    }
                  ],
                  "payment" => %{}
                }
              },
              "cargo" => %{
                "capacity" => 40,
                "units" => 11,
                "inventory" => [%{"symbol" => "IRON_ORE", "units" => 11}]
              }
            }
          })

        {"POST", "/v2/my/contracts/ctr-1/fulfill"} ->
          Elixir.Agent.update(game_state, fn _ -> :fulfilled end)

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

        request ->
          flunk("unexpected game request: #{inspect(request)}")
      end
    end)

    assert {:ok, %{fulfilled: true}} =
             FleetContracts.reconcile(Scope.for_operator(operator), agent, revision)

    assert Elixir.Agent.get(game_state, & &1) == :fulfilled
  end

  test "current Pledges shrink when another Agent advances the Contract" do
    {agent, _ship, portfolio, _commitment} = claimed_contract_ship()
    operator = Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id)

    second =
      Repo.insert!(%Ship{symbol: "CONTRACT-HAULER", ship_type: "SHIP_PROBE", agent_id: agent.id})

    other =
      Repo.insert!(%Commitment{
        fleet_commitment_portfolio_id: portfolio.id,
        candidate_id: "other-hauler",
        objective_index: 0,
        claims: [second.symbol],
        pledges: [
          %{
            "outcome" => ["contract", "ctr-1", "X1-UX81-A2", "IRON_ORE"],
            "amount" => 1,
            "backing" => ["claim", second.symbol]
          }
        ],
        reservations: %{},
        dependencies: [],
        expected_value: 1.0,
        unwind_cost: 0.0,
        decisive_reason: "shared delivery"
      })

    Repo.insert_all("fleet_commitment_claims", [
      %{
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_id: other.id,
        resource: second.symbol
      }
    ])

    {:ok, progress} = Elixir.Agent.start_link(fn -> 4 end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/my/contracts"
      fulfilled = Elixir.Agent.get(progress, & &1)

      Req.Test.json(conn, %{
        "data" => [
          %{
            "id" => "ctr-1",
            "accepted" => true,
            "fulfilled" => false,
            "terms" => %{
              "deadline" => "2099-01-01T00:00:00Z",
              "deliver" => [
                %{
                  "tradeSymbol" => "IRON_ORE",
                  "destinationSymbol" => "X1-UX81-A2",
                  "unitsRequired" => 5,
                  "unitsFulfilled" => fulfilled
                }
              ],
              "payment" => %{}
            }
          }
        ]
      })
    end)

    assert {:ok, [%{amount: 1}, %{amount: 0}]} =
             FleetContracts.current_pledges(Scope.for_operator(operator), agent)

    Elixir.Agent.update(progress, fn _ -> 5 end)

    assert {:ok, [%{amount: 0}, %{amount: 0}]} =
             FleetContracts.current_pledges(Scope.for_operator(operator), agent)
  end

  defp claimed_contract_ship do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    ship =
      Repo.insert!(%Ship{symbol: "CONTRACT-SHIP", ship_type: "SHIP_PROBE", agent_id: agent.id})

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

    candidate = %PortfolioCandidate{
      id: "deliver",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [
        %{
          outcome: {:contract, "ctr-1", "X1-UX81-A2", "IRON_ORE"},
          amount: 1,
          backing: {:claim, ship.symbol}
        }
      ],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "contracts-v1"
      })

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end
end
