defmodule SpaceTraders.FleetExecutionTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Test.CapacityDispositions
  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Agent.{Operator, Scope}
  alias SpaceTraders.Evidence.Observation
  alias SpaceTraders.Fleet.Intent
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetAllocation.Portfolio
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Intelligence

  @as_of ~U[2030-01-01 12:00:00Z]

  describe "governed_availability/1" do
    test "claims market reach from governed waypoint evidence" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.json(conn, %{
              "data" => %{
                "accountId" => "ACC",
                "symbol" => agent.symbol,
                "headquarters" => "X1-A1",
                "credits" => 42_000,
                "startingFaction" => "COSMIC",
                "shipCount" => 1
              }
            })

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("SHIP-1")]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:ok, availability} = FleetExecution.governed_availability(agent)

      assert [
               %{
                 resource: "SHIP-1",
                 roles: [:market_trader, :intelligence_scout],
                 capabilities: %{
                   cargo_transport: 40,
                   market_access: ["X1-A1", "X1-A2"]
                 }
               }
             ] = availability.claims

      assert availability.reservations == %{credits: 42_000}
      assert %DateTime{} = availability.as_of
    end

    test "reports unknown rather than zero capacity when evidence cannot be established" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{agent_token: nil})

      assert {:error, :availability_unknown} = FleetExecution.governed_availability(agent)
    end

    test "reports unknown when the Agent's credits are unavailable" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/agent" ->
            Req.Test.transport_error(conn, :timeout)

          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("SHIP-1")]})
        end
      end)

      assert {:error, :availability_unknown} = FleetExecution.governed_availability(agent)
    end

    defp observe_marketplace(agent, symbol) do
      waypoint =
        Waypoint.from_json(%{
          "symbol" => symbol,
          "systemSymbol" => "X1",
          "type" => "PLANET",
          "x" => 0,
          "y" => 0,
          "traits" => [%{"symbol" => "MARKETPLACE"}]
        })

      assert {:ok, _} = Intelligence.observe_waypoint(agent, waypoint, source: "get_waypoint")
    end
  end

  describe "reconcile_market_evidence/5" do
    test "selects a Market Fleet Commitment from governed Market reach" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)

      stub_market_agent(agent)

      assert {:ok, %{action: :deferred_for_capacity, comparison: comparison}} =
               FleetExecution.reconcile_market_evidence(
                 scope,
                 agent,
                 revision,
                 "X1",
                 sustained_capacity()
               )

      assert [%{candidate_id: candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices
      assert is_binary(candidate_id)
    end

    test "still rejects candidates when governed evidence misses a required Marketplace" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)

      stub_market_agent(agent)

      assert {:ok, %{action: :no_admissible_commitment, comparison: comparison}} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      assert comparison.proposed_choices == []

      assert Enum.all?(comparison.alternatives, fn alternative ->
               :claim_conflict in alternative.reasons
             end)

      assert Repo.aggregate(Portfolio, :count) == 0
    end

    test "proposes a profitable route from partial evidence while baseline coverage stays open" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      # A known third Marketplace without Listing evidence never blocks the
      # route the sufficient partial evidence supports.
      observe_marketplace(agent, "X1-A3")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)

      stub_market_agent(agent)

      assert {:ok, %{action: :deferred_for_capacity, comparison: comparison}} =
               FleetExecution.reconcile_market_evidence(
                 scope,
                 agent,
                 revision,
                 "X1",
                 sustained_capacity()
               )

      assert [%{candidate_id: _candidate_id, claims: ["SHIP-1"]}] = comparison.proposed_choices

      refute Enum.any?(
               Enum.flat_map(comparison.planning, & &1.limitations),
               &(&1.reason == :no_viable_market_routes)
             )
    end

    test "incomplete coverage reports unresolved subjects instead of an invalid negative conclusion" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      observe_marketplace(agent, "X1-A3")
      # Identical quotes leave no spread, and the never-observed A3 keeps the
      # baseline target incomplete.
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 10)

      stub_market_agent(agent)

      assert {:ok, %{action: :no_admissible_commitment, comparison: comparison}} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      limitations = Enum.flat_map(comparison.planning, & &1.limitations)

      refute Enum.any?(limitations, &(&1.reason == :no_viable_market_routes))

      assert %{
               subject: :market_planning,
               reason: :incomplete_market_coverage,
               subjects: ["market:X1:X1-A3"]
             } = Enum.find(limitations, &(&1.reason == :incomplete_market_coverage))
    end

    test "unknown governed availability reports its own disposition without a Neutral Wait" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [ship_body("SHIP-1")]})

          "/v2/my/agent" ->
            Req.Test.transport_error(conn, :timeout)

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert {:error, :availability_unknown} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      assert Repo.aggregate(StrategyDecisionEpisode, :count) == 0
    end

    test "hands the published Commitment to activation under normal API capacity" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)

      stub_activation_agent(agent)

      assert {:ok,
              %{
                action: :activated,
                commitment: %Commitment{} = commitment,
                portfolio: %Portfolio{},
                round_trip: %Intent{} = intent
              }} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      assert Repo.get!(Commitment, commitment.id) == commitment
      assert intent.fleet_commitment_id == commitment.id
      assert intent.type == "buy"
      assert Repo.aggregate(Portfolio, :count) == 1
    end

    # #589 runtime finding: a completed buy commits before its round trip
    # requests the sell leg. A Market re-observation landing in that window
    # fingerprinted a new candidate and superseded the Commitment, so the sell
    # leg was refused and the bought Cargo stayed aboard.
    test "keeps a Commitment between its completed buy and its sell leg" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)
      stub_activation_agent(agent)

      assert {:ok, %{action: :activated, portfolio: portfolio, round_trip: buy}} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      Repo.update!(
        Ecto.Changeset.change(buy, status: "completed", finished_at: DateTime.utc_now(:second))
      )

      market_observation(agent, "X1-A1", 10, "refreshed")

      assert {:error, :unresolved_commitment_evidence} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      assert %Portfolio{id: id, superseded_at: nil} =
               FleetAllocation.current_portfolio(scope, agent)

      assert id == portfolio.id
    end

    # The handoff guard is bounded: a completed buy whose next leg never
    # appeared cannot hold the Portfolio against replanning indefinitely.
    test "a completed buy stops protecting its Commitment once the leg handoff window passes" do
      {operator, agent, revision} = market_generation()
      scope = Scope.for_operator(operator)

      observe_marketplace(agent, "X1-A1")
      observe_marketplace(agent, "X1-A2")
      market_observation(agent, "X1-A1", 10)
      market_observation(agent, "X1-A2", 25)
      stub_activation_agent(agent)

      assert {:ok, %{action: :activated, portfolio: portfolio, round_trip: buy}} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      stale = DateTime.utc_now(:second) |> DateTime.add(-600, :second)
      Repo.update!(Ecto.Changeset.change(buy, status: "completed", finished_at: stale))
      market_observation(agent, "X1-A1", 10, "refreshed")

      assert {:ok, _} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, "X1", capacity())

      assert %Portfolio{superseded_at: %DateTime{}} = Repo.get!(Portfolio, portfolio.id)
    end

    defp market_generation do
      operator = Repo.insert!(%Operator{email: "market-#{System.unique_integer()}@example.com"})

      agent =
        Repo.insert!(%SpaceTraders.Agent.Agent{
          symbol: "MARKETACQ",
          faction: "COSMIC",
          headquarters: "X1-A1",
          agent_token: "test-agent-token",
          operator_id: operator.id
        })

      Repo.insert!(%Ship{symbol: "SHIP-1", ship_type: "SHIP_FRIGATE", agent_id: agent.id})

      strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

      revision =
        Repo.insert!(%Revision{
          fleet_strategy_id: strategy.id,
          number: 1,
          document: %{
            "objectives" => [
              %{
                "objective" => "Grow credits",
                "kind" => "continuous",
                "evaluation" => "Maximize net credit growth over time",
                "scope" => "recurring"
              }
            ],
            "hard_constraints" => ["Keep at least 500 credits available"]
          },
          source: "operator",
          activated_at: DateTime.utc_now(:second)
        })

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

      Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

      {operator, agent, revision}
    end

    defp market_observation(agent, waypoint, purchase_price, variant \\ "") do
      Repo.insert!(%Observation{
        agent_id: agent.id,
        subject: "market:X1:#{waypoint}",
        operation_id: "get-market",
        dependency_keys: ["market:X1:#{waypoint}"],
        facts: %{
          "trade_goods" => [
            %{
              "symbol" => "IRON",
              "purchase_price" => purchase_price,
              "sell_price" => purchase_price - 1,
              "trade_volume" => 20,
              "supply" => "MODERATE",
              "activity" => "STATIC"
            }
          ]
        },
        response_fingerprint: "market-#{waypoint}-#{purchase_price}#{variant}",
        observed_at: SpaceTraders.Clock.utc_now()
      })
    end

    defp stub_market_agent(agent) do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "accountId" => "ACC",
                "symbol" => agent.symbol,
                "headquarters" => agent.headquarters,
                "credits" => 5_000,
                "startingFaction" => "COSMIC",
                "shipCount" => 1
              }
            })

          {"GET", "/v2/my/ships"} ->
            Req.Test.json(conn, %{"data" => [ship_body("SHIP-1")]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)
    end

    defp stub_activation_agent(agent) do
      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "accountId" => "ACC",
                "symbol" => agent.symbol,
                "headquarters" => agent.headquarters,
                "credits" => 5_000,
                "startingFaction" => "COSMIC",
                "shipCount" => 1
              }
            })

          {"GET", "/v2/my/ships"} ->
            Req.Test.json(conn, %{"data" => [ship_body("SHIP-1")]})

          {"GET", "/v2/my/ships/SHIP-1"} ->
            nav =
              nav_body("DOCKED")
              |> Map.put("systemSymbol", "X1")
              |> Map.put("waypointSymbol", "X1-A1")

            cargo = %{
              "capacity" => 40,
              "units" => 40,
              "inventory" => [%{"symbol" => "IRON", "units" => 40}]
            }

            Req.Test.json(conn, %{
              "data" => ship_body("SHIP-1", %{"nav" => nav, "cargo" => cargo})
            })

          {"GET", "/v2/systems/X1/waypoints/X1-A1/market"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-A1",
                "tradeGoods" => [
                  %{
                    "symbol" => "IRON",
                    "purchasePrice" => 10,
                    "sellPrice" => 9,
                    "tradeVolume" => 20,
                    "supply" => "MODERATE",
                    "activity" => "STATIC"
                  }
                ]
              }
            })

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)
    end

    defp capacity, do: CapacityDispositions.proceed(@as_of)

    defp sustained_capacity do
      CapacityDispositions.defer(@as_of)
    end
  end

  describe "reservation_covers_exposure?/3" do
    test "accepts a reservation that covers worst-case exposure within the floor" do
      commitment = commitment(%{credits: 200})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      availability = %{reservations: %{credits: 2_000}}

      assert FleetExecution.reservation_covers_exposure?(commitment, revision, availability)
    end

    test "rejects a reservation that would cross the Hard Constraint floor" do
      commitment = commitment(%{credits: 900})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      availability = %{reservations: %{credits: 1_000}}

      refute FleetExecution.reservation_covers_exposure?(commitment, revision, availability)
    end

    test "rejects a commitment without a numeric credit reservation" do
      commitment = commitment(%{})
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      refute FleetExecution.reservation_covers_exposure?(commitment, revision, %{
               reservations: %{credits: 1_000}
             })
    end

    test "rejects when no enforceable credit floor is declared" do
      commitment = commitment(%{credits: 200})

      refute FleetExecution.reservation_covers_exposure?(commitment, revision(%{}), %{
               reservations: %{credits: 1_000}
             })
    end
  end

  describe "eligible_market_commitment/4" do
    test "returns the shadow-validated proposed choice that claims an owned Ship" do
      agent = agent_fixture(operator_fixture())
      owned = %{claims: ["SHIP-1"], reservations: %{credits: 200}, candidate_id: "candidate-1"}

      other = %{
        claims: ["SHIP-OTHER"],
        reservations: %{credits: 200},
        candidate_id: "candidate-2"
      }

      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      comparison = %{proposed_choices: [other, owned]}

      assert %{claims: ["SHIP-1"]} =
               FleetExecution.eligible_market_commitment(
                 comparison,
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end

    test "returns nil when no proposed choice claims an owned Ship" do
      agent = agent_fixture(operator_fixture())
      other = %{claims: ["SHIP-OTHER"], reservations: %{credits: 200}}
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert nil ==
               FleetExecution.eligible_market_commitment(
                 %{proposed_choices: [other]},
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end

    test "returns nil when the proposed choice's reservation crosses the floor" do
      agent = agent_fixture(operator_fixture())
      choice = %{claims: ["SHIP-1"], reservations: %{credits: 1_501}}
      revision = revision(%{"hard_constraints" => ["Keep at least 500 credits available"]})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case conn.request_path do
          "/v2/my/ships" ->
            Req.Test.json(conn, %{"data" => [%{"symbol" => "SHIP-1"}]})

          other ->
            flunk("unexpected request: #{inspect(other)}")
        end
      end)

      assert nil ==
               FleetExecution.eligible_market_commitment(
                 %{proposed_choices: [choice]},
                 agent,
                 revision,
                 %{reservations: %{credits: 2_000}}
               )
    end
  end

  describe "credit_floor/1" do
    test "returns the floor declared as a Hard Constraint" do
      assert {:ok, 50_000} =
               FleetExecution.credit_floor(
                 revision(%{"hard_constraints" => ["Keep at least 50,000 credits available"]})
               )
    end
  end

  defp commitment(reservations) do
    %{
      candidate_id: "candidate-1",
      claims: ["SHIP-1"],
      reservations: reservations
    }
  end

  defp revision(document) do
    %Revision{id: 42, document: document}
  end
end
