defmodule SpaceTraders.MissionControlTest do
  # Current-Fleet adoption serializes deployment identity, not per-tenant state.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.EvidenceFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.FleetAllocation.Commitment
  alias SpaceTraders.FleetAllocation.StrategyDecisionEpisode
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Intelligence
  alias SpaceTraders.MissionControl

  describe "fleet_snapshot/1" do
    test "reads only the published Fleet, never retained historical Agents" do
      operator = operator_fixture()
      own_agent = agent_fixture(operator, %{agent_token: nil})

      _historical = agent_fixture(operator, %{agent_token: nil})

      assert %{agent: %{id: agent_id}} =
               MissionControl.fleet_snapshot(Scope.for_operator(operator))

      assert agent_id == own_agent.id
    end

    test "does not expose AgentTokens in Operator projections" do
      operator = operator_fixture()
      _agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN_SECRET"})
      Req.Test.stub(SpaceTraders.API, &unavailable_response/1)
      scope = Scope.for_operator(operator)

      assert %{agent: %{agent_token: nil}} = MissionControl.fleet_snapshot(scope)
    end

    test "dashboard never acquires on-site Market or Shipyard listings" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{headquarters: "X1-UX81-A1"})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/my/agent"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "accountId" => "ACC",
                "symbol" => agent.symbol,
                "headquarters" => "X1-UX81-A1",
                "credits" => 50_000,
                "startingFaction" => "COSMIC",
                "shipCount" => 1
              }
            })

          {"GET", "/v2/my/ships"} ->
            Req.Test.json(conn, %{
              "data" => [ship_body("DASH-1", %{"nav" => nav_body("DOCKED")})]
            })

          {"GET", "/v2/my/contracts"} ->
            Req.Test.json(conn, %{"data" => []})

          {"GET", "/v2/systems/X1-UX81/waypoints"} ->
            Req.Test.json(conn, %{
              "data" => [
                %{
                  "symbol" => "X1-UX81-A1",
                  "systemSymbol" => "X1-UX81",
                  "type" => "ORBITAL_STATION",
                  "x" => 0,
                  "y" => 0,
                  "orbitals" => [],
                  "traits" => [
                    %{"symbol" => "MARKETPLACE"},
                    %{"symbol" => "SHIPYARD"}
                  ]
                }
              ]
            })

          request ->
            flunk("dashboard requested on-site intelligence: #{inspect(request)}")
        end
      end)

      assert %{markets: {:ok, []}, shipyards: {:ok, []}} =
               MissionControl.fleet_snapshot(Scope.for_operator(operator))
    end

    test "retirement fences a prior current snapshot instead of reviving its Agent" do
      operator = operator_fixture()
      agent = agent_fixture(operator, %{agent_token: nil})
      scope = Scope.for_operator(operator)
      assert %{agent: %{id: id}} = MissionControl.fleet_snapshot(scope)
      assert id == agent.id
      generation = Repo.get_by!(SpaceTraders.FleetGeneration.Generation, agent_id: agent.id)
      generation |> Ecto.Changeset.change(retired_at: DateTime.utc_now()) |> Repo.update!()
      assert %{stale?: true} = MissionControl.fleet_snapshot(scope)
    end

    test "uses only read requests and preserves unavailable values" do
      operator = operator_fixture()
      agent = agent_fixture(operator)
      test_pid = self()

      Req.Test.stub(SpaceTraders.API, fn conn ->
        send(test_pid, {:request, conn.method, conn.request_path})

        if conn.method != "GET",
          do: send(test_pid, {:mutation_request, conn.method, conn.request_path})

        unavailable_response(conn)
      end)

      assert projection = MissionControl.fleet_snapshot(Scope.for_operator(operator))
      assert projection.agent.id == agent.id
      assert {:error, _reason} = projection.overview
      assert {:error, _reason} = projection.ships
      assert {:error, _reason} = projection.contracts
      assert {:ok, []} = projection.waypoints

      assert_received {:request, "GET", "/v2/my/agent"}
      assert_received {:request, "GET", "/v2/my/ships"}
      assert_received {:request, "GET", "/v2/my/contracts"}
      refute_received {:request, "GET", "/v2/systems/X1-UX81/waypoints"}
      refute_received {:mutation_request, _method, _path}
    end
  end

  describe "current-Fleet refresh" do
    test "replaces previously current values with truthful unavailable results" do
      operator = operator_fixture()
      agent = agent_fixture(operator)
      {:ok, state} = Agent.start_link(fn -> :available end)

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case Agent.get(state, & &1) do
          :available -> available_response(conn, agent.symbol)
          :unavailable -> unavailable_response(conn)
        end
      end)

      scope = Scope.for_operator(operator)

      assert %{overview: {:ok, _agent}, ships: {:ok, []}} = MissionControl.fleet_snapshot(scope)

      Agent.update(state, fn _ -> :unavailable end)

      assert %{overview: {:error, _overview_reason}, ships: {:error, _ships_reason}} =
               MissionControl.fleet_snapshot(scope)
    end

    test "a forged authentication scope cannot refresh the published Fleet" do
      operator = operator_fixture()
      _own_agent = agent_fixture(operator, %{agent_token: nil})
      forged = Scope.for_operator(%SpaceTraders.Agent.Operator{id: -1})
      Req.Test.stub(SpaceTraders.API, fn _ -> flunk("unauthorized Fleet read") end)
      assert MissionControl.fleet_snapshot(forged) == nil
    end
  end

  test "history projections answer only the deployment Operator; a legacy identity selects nothing" do
    deployment_scope = Scope.for_operator(operator_fixture())
    legacy = legacy_operator_fixture()
    legacy_scope = Scope.for_operator(legacy)
    alias SpaceTraders.FleetGeneration.Generation
    alias SpaceTraders.FleetStrategy.{Revision, Strategy}

    strategy = Repo.insert!(%Strategy{operator_id: legacy.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    generation =
      SpaceTraders.AgentFixtures.generation_fixture(%Generation{
        operator_id: legacy.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: "LEGACYHIST",
        faction: "COSMIC",
        replacement_symbols: %{},
        retired_at: DateTime.utc_now()
      })

    episode =
      Repo.insert!(%StrategyDecisionEpisode{
        operator_id: legacy.id,
        fleet_generation_id: generation.id,
        fleet_strategy_revision_id: revision.id,
        source_version: 0,
        calibration_version: "market-v1"
      })

    assert MissionControl.generation_recaps(legacy_scope) == []
    assert MissionControl.decision_episode(legacy_scope, episode.id) == nil
    assert MissionControl.decision_episode_comparison(legacy_scope) == []

    # The retained legacy rows keep their original attribution.
    assert Repo.get!(StrategyDecisionEpisode, episode.id).fleet_generation_id == generation.id

    assert MissionControl.decision_episode(deployment_scope, episode.id)
    assert [%{id: id}] = MissionControl.decision_episode_comparison(deployment_scope)
    assert id == episode.id

    assert [%{revisions: [1]}] = MissionControl.generation_recaps(deployment_scope)
  end

  describe "strategy/1" do
    test "compares a draft with the active revision and projects governed planning consequences" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      active = %{
        "objectives" => [
          %{
            "objective" => "Grow credits",
            "kind" => "continuous",
            "evaluation" => "Measure growth",
            "scope" => "recurring"
          }
        ],
        "hard_constraints" => ["Keep at least 50,000 credits available"],
        "preferences" => ["Prefer lower-risk routes"],
        "consequences" => "The Fleet may spend credits above the floor."
      }

      draft = %{
        "objectives" => [
          %{
            "objective" => "Chart waypoints",
            "kind" => "attain",
            "evaluation" => "Increase coverage",
            "scope" => "fleet_generation"
          },
          %{
            "objective" => "Grow credits",
            "kind" => "continuous",
            "evaluation" => "Measure growth",
            "scope" => "recurring"
          }
        ],
        "hard_constraints" => ["Keep at least 75,000 credits available"],
        "preferences" => ["Prefer lower-risk routes"],
        "consequences" => "The Fleet may delay growth while charting."
      }

      assert {:ok, _draft} = FleetStrategy.save_draft(scope, active, 0)
      assert {:ok, revision} = FleetStrategy.activate(scope, 1)
      assert {:ok, _draft} = FleetStrategy.save_draft(scope, draft, 2)

      observe_market_pair(agent)

      projection = MissionControl.strategy_review(scope)

      assert projection.draft == draft
      assert projection.draft_comparison.changed?

      assert [%{"objective" => "Chart waypoints"}] = projection.draft_comparison.objectives.added

      assert projection.draft_comparison.hard_constraints.added == [
               "Keep at least 75,000 credits available"
             ]

      assert projection.draft_comparison.hard_constraints.removed == [
               "Keep at least 50,000 credits available"
             ]

      assert [
               %{
                 objective_index: 0,
                 planning: %{
                   candidate_contributions: [],
                   limitations: [%{reason: :unsupported_market_objective}]
                 }
               },
               %{
                 objective_index: 1,
                 planning: %{candidate_contributions: [candidate | _]}
               }
             ] = projection.draft_consequences

      assert Enum.map(projection.draft_consequences, & &1.agent.id) == [agent.id, agent.id]
      assert candidate.strategy_revision_id != revision.id
    end

    test "shadow-evaluates the draft's likely Fleet Commitments under governed availability" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      document = %{
        "objectives" => [
          %{
            "objective" => "Grow credits",
            "kind" => "continuous",
            "evaluation" => "Measure growth",
            "scope" => "recurring"
          }
        ],
        "hard_constraints" => ["Keep at least 50,000 credits available"],
        "preferences" => ["Prefer lower-risk routes"],
        "consequences" => "The Fleet may spend credits above the floor."
      }

      assert {:ok, _draft} = FleetStrategy.save_draft(scope, document, 0)
      assert {:ok, _revision} = FleetStrategy.activate(scope, 1)

      assert {:ok, _draft} =
               FleetStrategy.save_draft(
                 scope,
                 Map.put(document, "consequences", "Growth may slow."),
                 2
               )

      observe_market_pair(agent)

      availability = %{
        agent.id => %{
          as_of: DateTime.utc_now(),
          claims: [
            %{
              resource: "SHIP-1",
              roles: [:market_trader],
              capabilities: %{cargo_transport: 40, market_access: ["X1-A1", "X1-A2"]}
            }
          ],
          reservations: %{credits: 100_000}
        }
      }

      projection =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope),
          availability: availability
        )

      assert [
               %{
                 agent: %{id: agent_id},
                 availability: :authoritative,
                 active: %{expectations: %{commitment_count: 1, expected_value: 200}},
                 draft: %{
                   expectations: %{commitment_count: 1, expected_value: 200},
                   commitments: [commitment],
                   rejected: []
                 }
               }
             ] = projection.draft_commitments

      assert agent_id == agent.id
      assert commitment.claims == ["SHIP-1"]
      assert commitment.expected_value == 200
      assert Repo.aggregate(Commitment, :count) == 0
    end

    test "states unknown availability instead of assuming zero capacity" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      assert {:ok, _draft} =
               FleetStrategy.save_draft(
                 scope,
                 %{
                   "objectives" => [%{"objective" => "Grow credits"}],
                   "hard_constraints" => ["No scrap"],
                   "preferences" => [],
                   "consequences" => "Not yet specified"
                 },
                 0
               )

      projection =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope),
          availability: %{agent.id => nil}
        )

      assert [%{availability: :unknown, active: nil, draft: nil}] = projection.draft_commitments
    end

    test "reports insufficient governed evidence rather than a zero commitment count" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)
      agent = agent_fixture(operator, %{headquarters: "X1-A1"})

      assert {:ok, _draft} =
               FleetStrategy.save_draft(
                 scope,
                 %{
                   "objectives" => [
                     %{
                       "objective" => "Grow credits",
                       "kind" => "continuous",
                       "evaluation" => "Measure growth",
                       "scope" => "recurring"
                     }
                   ],
                   "hard_constraints" => ["Keep at least 50,000 credits available"],
                   "preferences" => [],
                   "consequences" => "The Fleet may spend credits above the floor."
                 },
                 0
               )

      availability = %{
        agent.id => %{
          as_of: DateTime.utc_now(),
          claims: [
            %{
              resource: "SHIP-1",
              roles: [:market_trader],
              capabilities: %{cargo_transport: 40, market_access: ["X1-A1", "X1-A2"]}
            }
          ],
          reservations: %{credits: 100_000}
        }
      }

      projection =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope),
          availability: availability
        )

      assert [
               %{
                 availability: :authoritative,
                 active: nil,
                 draft: %{
                   commitments: [],
                   rejected: [],
                   limitations: [%{reason: :insufficient_market_evidence}]
                 }
               }
             ] = projection.draft_commitments
    end

    test "reports no draft comparison until an active revision exists" do
      operator = operator_fixture()
      scope = Scope.for_operator(operator)
      _agent = agent_fixture(operator)

      assert {:ok, _draft} =
               FleetStrategy.save_draft(
                 scope,
                 %{
                   "objectives" => [%{"objective" => "Grow credits"}],
                   "hard_constraints" => ["No scrap"],
                   "preferences" => [],
                   "consequences" => "Not yet specified"
                 },
                 0
               )

      assert MissionControl.strategy(scope).draft_comparison == nil
    end
  end

  describe "market_planning/2" do
    test "projects a profitable route from partial evidence while baseline coverage stays incomplete" do
      {scope, agent} = credit_growth_fixture()

      observe_market_pair(agent)
      # A known third Marketplace without Listing evidence stays unresolved.
      observe_waypoint(agent, "X1-A3")

      assert [%{objective_index: 0, planning: planning}] = MissionControl.market_planning(scope)

      assert planning.candidate_contributions != []

      refute Enum.any?(planning.limitations, &(&1.reason == :no_viable_market_routes))

      # The never-observed Marketplace stays an explicit gap of the shared
      # interpretation the projection planned from.
      assert %{reason: :never_observed} =
               agent
               |> Intelligence.market_interpretation("X1", DateTime.utc_now())
               |> Map.fetch!(:coverage_gaps)
               |> Enum.find(&(&1.subject == "market:X1:X1-A3"))
    end

    test "projects incomplete coverage as an explicit limitation instead of an invalid negative conclusion" do
      {scope, agent} = credit_growth_fixture()

      Enum.each(["X1-A1", "X1-A2", "X1-A3"], &observe_waypoint(agent, &1))
      # Identical quotes leave no spread, and the never-observed A3 keeps the
      # baseline target incomplete.
      observe_market(agent, "X1-A1", 10, 9)
      observe_market(agent, "X1-A2", 10, 9)

      assert [%{objective_index: 0, planning: planning}] = MissionControl.market_planning(scope)

      assert planning.candidate_contributions == []

      refute Enum.any?(planning.limitations, &(&1.reason == :no_viable_market_routes))

      assert %{
               subject: :market_planning,
               reason: :incomplete_market_coverage,
               subjects: ["market:X1:X1-A3"]
             } = Enum.find(planning.limitations, &(&1.reason == :incomplete_market_coverage))
    end
  end

  describe "captured Market decision" do
    setup do
      {scope, agent} = credit_growth_fixture()
      active = FleetStrategy.get(scope).active_revision.document

      assert {:ok, _draft} = FleetStrategy.save_draft(scope, active, 2)
      observe_market_pair(agent)

      availability = %{
        agent.id => %{
          as_of: DateTime.utc_now(),
          claims: [
            %{
              resource: "SHIP-1",
              roles: [:market_trader],
              capabilities: %{cargo_transport: 40, market_access: ["X1-A1", "X1-A2"]}
            }
          ],
          reservations: %{credits: 100_000}
        }
      }

      %{scope: scope, agent: agent, availability: availability}
    end

    test "active, draft and planning evaluate one captured input after later evidence", ctx do
      %{scope: scope, agent: agent, availability: availability} = ctx

      capture = MissionControl.capture_market_decision(scope, availability: availability)

      review =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope), market_decision: capture)

      planning = MissionControl.market_planning(scope, capture)

      # A newer observation arrives after capture; the captured evaluation
      # must not see it.
      observe_market(agent, "X1-A1", 90, 89)

      later_review =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope), market_decision: capture)

      assert later_review.draft_commitments == review.draft_commitments
      assert later_review.draft_consequences == review.draft_consequences
      assert MissionControl.market_planning(scope, capture) == planning

      # An unchanged draft equals the active revision, so both sides of the
      # comparison interpret the same facts identically.
      assert [%{active: active_side, draft: draft_side}] = review.draft_commitments
      # Candidate identities embed the (draft vs active) revision identity.
      strip =
        &update_in(&1.commitments, fn cs ->
          Enum.map(cs, fn c -> Map.delete(c, :candidate_id) end)
        end)

      assert strip.(active_side) == strip.(draft_side)
      assert active_side.expectations.commitment_count == 1
    end

    test "keeps original observation time instead of the review clock", %{scope: scope} = ctx do
      capture = MissionControl.capture_market_decision(scope, availability: ctx.availability)

      assert [%{market_input: input}] = capture.agents
      assert input.as_of == capture.as_of
      assert [_ | _] = input.markets

      for market <- input.markets, market.state == :current do
        assert DateTime.compare(market.observed_at, capture.as_of) == :lt
      end
    end

    test "review captures and plans without gameplay requests or published work", ctx do
      %{scope: scope, availability: availability} = ctx
      test_pid = self()
      Req.Test.stub(SpaceTraders.API, fn conn -> send(test_pid, :gameplay_request) && conn end)

      counts = fn ->
        Enum.map(
          [
            SpaceTraders.Evidence.ObservationDemand,
            SpaceTraders.FleetAllocation.Commitment,
            SpaceTraders.FleetAllocation.Portfolio,
            SpaceTraders.FleetAllocation.StrategyDecisionEpisode,
            SpaceTraders.Evidence.Observation
          ],
          &Repo.aggregate(&1, :count)
        )
      end

      before = counts.()

      capture = MissionControl.capture_market_decision(scope, availability: availability)

      _ =
        MissionControl.strategy_review(scope, FleetStrategy.get(scope), market_decision: capture)

      _ = MissionControl.market_planning(scope, capture)

      assert counts.() == before
      refute_received :gameplay_request
    end

    test "a captured decision is stale after a changed observation or Fleet Generation", ctx do
      %{scope: scope, agent: agent, availability: availability} = ctx

      capture = MissionControl.capture_market_decision(scope, availability: availability)
      assert MissionControl.market_decision_current?(scope, capture)

      observe_market(agent, "X1-A1", 90, 89)
      refute MissionControl.market_decision_current?(scope, capture)

      recaptured = MissionControl.capture_market_decision(scope, availability: availability)
      assert MissionControl.market_decision_current?(scope, recaptured)

      Repo.get_by!(SpaceTraders.FleetGeneration.Generation, agent_id: agent.id)
      |> Ecto.Changeset.change(fenced_at: DateTime.utc_now())
      |> Repo.update!()

      refute MissionControl.market_decision_current?(scope, recaptured)
    end
  end

  defp credit_growth_fixture do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{headquarters: "X1-A1"})

    assert {:ok, _draft} =
             FleetStrategy.save_draft(
               scope,
               %{
                 "objectives" => [
                   %{
                     "objective" => "Grow credits",
                     "kind" => "continuous",
                     "evaluation" => "Measure growth",
                     "scope" => "recurring"
                   }
                 ],
                 "hard_constraints" => ["Keep at least 50,000 credits available"],
                 "preferences" => [],
                 "consequences" => "The Fleet may spend credits above the floor."
               },
               0
             )

    assert {:ok, _revision} = FleetStrategy.activate(scope, 1)

    {scope, agent}
  end

  defp observe_market_pair(agent) do
    Enum.each(["X1-A1", "X1-A2"], &observe_waypoint(agent, &1))
    observe_market(agent, "X1-A1", 10, 9)
    observe_market(agent, "X1-A2", 25, 20)
  end

  defp observe_waypoint(agent, symbol) do
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

  defp observe_market(agent, waypoint, purchase_price, sell_price) do
    governed_market_observation(agent, "X1", waypoint, purchase_price, sell_price)
  end

  defp available_response(conn, symbol) do
    case conn.request_path do
      "/v2/my/agent" ->
        Req.Test.json(conn, %{
          "data" => %{
            "accountId" => "ACC",
            "symbol" => symbol,
            "headquarters" => "X1-UX81-A1",
            "credits" => 42_000,
            "startingFaction" => "COSMIC",
            "shipCount" => 0
          }
        })

      "/v2/my/ships" ->
        Req.Test.json(conn, %{"data" => []})

      "/v2/my/contracts" ->
        Req.Test.json(conn, %{"data" => []})

      "/v2/systems/X1-UX81/waypoints" ->
        Req.Test.json(conn, %{"data" => []})
    end
  end

  defp unavailable_response(conn) do
    conn
    |> Map.put(:status, 400)
    |> Req.Test.json(%{"error" => %{"message" => "Projection unavailable"}})
  end
end
