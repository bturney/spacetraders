defmodule SpaceTraders.FleetStrategyTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.EmergencyStopAdmission
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Intents, Job, Ship}
  alias SpaceTraders.FleetGeneration
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.FleetStrategy.Revision
  alias SpaceTraders.Repo

  test "Emergency Stop is durable and scoped to its Operator" do
    scope = operator_fixture() |> Scope.for_operator()
    other_scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert %DateTime{} = stopped.emergency_stopped_at
    assert stopped.emergency_stop_version == 1

    assert FleetStrategy.get(scope).emergency_stopped_at == stopped.emergency_stopped_at
    assert FleetStrategy.get(other_scope).emergency_stopped_at == nil

    assert {:ok, reengaged} = FleetStrategy.engage_emergency_stop(scope)
    assert reengaged.emergency_stop_version == stopped.emergency_stop_version + 1
  end

  test "resume rejects stale Operator state and keeps admission stopped for fresh planning" do
    scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert {:error, :emergency_stopped} = FleetStrategy.authorize(scope, %{})
    assert {:error, :stale_emergency_stop} = FleetStrategy.resume(scope, 0)

    assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)
    assert prepared.emergency_stopped_at == stopped.emergency_stopped_at
    assert %DateTime{} = prepared.emergency_resume_prepared_at
    assert prepared.emergency_stop_version == stopped.emergency_stop_version + 1
    assert {:error, :emergency_stopped} = FleetStrategy.authorize(scope, %{})

    assert {:ok, stopped_again} = FleetStrategy.engage_emergency_stop(scope)
    assert stopped_again.emergency_stop_version == prepared.emergency_stop_version + 1
    assert stopped_again.emergency_resume_prepared_at == nil
  end

  test "fresh Fleet Allocation completes resume before mutation admission reopens" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_FRESH_PLAN_AGENT_TOKEN"})
    revision = activate_document(scope, document("Grow credits", "No scrap"))

    {:ok, evaluation} =
      FleetStrategy.evaluate_objective(revision, 0, %{
        change: 10,
        elapsed_seconds: 10,
        horizon_seconds: 60,
        feasible?: true
      })

    stale_plan = %{
      id: :pre_stop,
      objective_evaluations: [evaluation],
      preference_evaluations: [preference_evaluation(revision, 0, 1)],
      safety: safety_bounds(revision, %{scraps_ship: false})
    }

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => 175_000,
              "startingFaction" => agent.faction,
              "shipCount" => 0
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => []})
      end
    end)

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)

    assert {:error, :emergency_stopped} =
             EmergencyStopAdmission.mutation_allowed?(agent.agent_token)

    assert {:error, :fresh_plan_required} =
             FleetAllocation.complete_emergency_stop_resume(
               scope,
               [stale_plan],
               prepared.emergency_stop_version
             )

    fresh_plan = %{
      id: :post_stop,
      objective_evaluations: [evaluation],
      preference_evaluations: [preference_evaluation(revision, 0, 1)],
      safety: safety_bounds(revision, %{scraps_ship: false})
    }

    assert {:ok, %{strategy: resumed, ranking: %{admissible: [^fresh_plan]}}} =
             FleetAllocation.complete_emergency_stop_resume(
               scope,
               [fresh_plan],
               prepared.emergency_stop_version
             )

    assert resumed.emergency_stopped_at == nil
    assert resumed.emergency_resume_prepared_at == nil
    assert :ok = EmergencyStopAdmission.mutation_allowed?(agent.agent_token)
  end

  test "resume discards stale work but preserves in-flight mutation evidence for reconciliation" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_DISCARD_AGENT_TOKEN"})

    queued_ship =
      Repo.insert!(%Ship{symbol: "QUEUED-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    in_flight_ship =
      Repo.insert!(%Ship{symbol: "IN-FLIGHT-1", ship_type: "SHIP_PROBE", agent_id: agent.id})

    Repo.insert!(%Job{
      type: "explorer",
      status: "active",
      extraction_waypoint: "X1-UX81-A1",
      market_waypoint: "X1-UX81-A1",
      cargo_threshold: 1,
      ship_id: queued_ship.id
    })

    queued_intent =
      Repo.insert!(%Intent{ship_id: queued_ship.id, target_waypoint: "X1-UX81-A2"})

    in_flight_intent =
      Repo.insert!(%Intent{
        ship_id: in_flight_ship.id,
        target_waypoint: "X1-UX81-A2",
        status: "waiting",
        in_flight_action: %{"kind" => "navigate"}
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/agent" ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => agent.symbol,
              "headquarters" => agent.headquarters,
              "credits" => 175_000,
              "startingFaction" => agent.faction,
              "shipCount" => 2
            }
          })

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => []})
      end
    end)

    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)

    assert {:error, :reconciliation_required} =
             FleetStrategy.resume(scope, stopped.emergency_stop_version)

    assert FleetStrategy.get(scope).emergency_stopped_at == stopped.emergency_stopped_at
    assert Fleet.ship_job(agent, queued_ship.symbol).status == "active"
    assert Enum.any?(Intents.current(agent), &(&1.id == queued_intent.id))
    assert Enum.any?(Intents.current(agent), &(&1.id == in_flight_intent.id))

    Repo.update!(
      Ecto.Changeset.change(in_flight_intent,
        status: "completed",
        in_flight_action: nil,
        finished_at: DateTime.utc_now(:second)
      )
    )

    assert {:ok, prepared} = FleetStrategy.resume(scope, stopped.emergency_stop_version)
    assert %DateTime{} = prepared.emergency_resume_prepared_at
    assert %DateTime{} = prepared.emergency_stopped_at
    assert Fleet.ship_job(agent, queued_ship.symbol) == nil
    assert [%Job{status: "stopped"}] = Fleet.ship_job_history(agent, queued_ship.symbol)

    assert Enum.any?(
             Intents.history(agent),
             &(&1.id == queued_intent.id and &1.status == "superseded")
           )
  end

  test "credential replacement cannot release an in-flight token during Emergency Stop" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    old_token = "STOP_OLD_ACCOUNT_TOKEN"
    new_token = "STOP_NEW_ACCOUNT_TOKEN"

    assert {:ok, operator} = Agent.link_account_token(operator, old_token)
    assert {:ok, _stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert {:ok, _operator} = Agent.link_account_token(operator, new_token)
    assert {:ok, _reengaged} = FleetStrategy.engage_emergency_stop(scope)

    assert {:error, :emergency_stopped} = EmergencyStopAdmission.mutation_allowed?(old_token)
    assert {:error, :emergency_stopped} = EmergencyStopAdmission.mutation_allowed?(new_token)
  end

  test "Emergency Stop admission reconstructs from durable state after process restart" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_RESTART_AGENT_TOKEN"})

    assert {:ok, _stopped} = FleetStrategy.engage_emergency_stop(scope)
    assert :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, EmergencyStopAdmission)
    assert {:ok, _pid} = Supervisor.restart_child(SpaceTraders.Supervisor, EmergencyStopAdmission)

    assert {:error, :emergency_stopped} =
             EmergencyStopAdmission.mutation_allowed?(agent.agent_token)
  end

  test "resume keeps mutations stopped until authoritative refresh succeeds" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator, %{agent_token: "STOP_REFRESH_AGENT_TOKEN"})
    assert {:ok, stopped} = FleetStrategy.engage_emergency_stop(scope)

    Req.Test.stub(SpaceTraders.API, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, :authoritative_refresh_required} =
             FleetStrategy.resume(scope, stopped.emergency_stop_version)

    assert {:error, :emergency_stopped} =
             SpaceTraders.API.accept_contract(agent.agent_token, "contract-1")
  end

  test "presets disclose ordered objectives, Hard Constraints, Preferences, and consequences" do
    assert [preset | _] = FleetStrategy.presets()

    assert %{
             id: "steady_growth",
             objectives: [
               %{
                 "objective" => "Grow credits",
                 "kind" => "continuous",
                 "evaluation" => "Maximize net credit growth over time",
                 "scope" => "recurring"
               }
             ],
             hard_constraints: ["Keep at least 50,000 credits available"],
             preferences: ["Prefer lower-risk routes when expected returns are similar"],
             consequences: consequences
           } = preset

    assert consequences =~ "spend credits"
  end

  test "explicit activation snapshots the durable draft as an immutable revision" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "Keep 50,000 credits available")
    recommendation = document("Chart waypoints", "Keep 75,000 credits available")

    assert {:ok, %{draft: ^original, active_revision: nil}} =
             save_draft(scope, original)

    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    assert revision.number == 1
    assert revision.document == original

    assert {:ok, %{draft: ^recommendation, active_revision: active}} =
             FleetStrategy.recommend(scope, recommendation)

    assert active.id == revision.id
    assert active.document == original
    assert FleetStrategy.get(scope).active_revision.document == original
  end

  test "discarding a draft leaves the active revision unchanged" do
    scope = operator_fixture() |> Scope.for_operator()
    active_document = document("Grow credits", "Keep 50,000 credits available")

    assert {:ok, _draft} = save_draft(scope, active_document)
    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert {:ok, _draft} =
             save_draft(scope, document("Chart waypoints", "No scrap"))

    assert {:ok, %{draft: nil, active_revision: active}} =
             FleetStrategy.discard_draft(scope, FleetStrategy.get(scope).draft_version)

    assert active.id == revision.id
    assert active.document == active_document
  end

  test "an Operator cannot read or activate another Operator's Fleet Strategy" do
    owner_scope = operator_fixture() |> Scope.for_operator()
    other_scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, _draft} =
             save_draft(owner_scope, document("Grow credits", "No scrap"))

    assert %{draft: nil, active_revision: nil} = FleetStrategy.get(other_scope)
    assert {:error, :draft_not_found} = FleetStrategy.activate(other_scope, 0)
  end

  test "preset selection cannot silently replace an existing draft" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "No scrap")

    assert {:ok, _draft} = save_draft(scope, original)
    assert {:error, :draft_exists} = FleetStrategy.select_preset(scope, "steady_growth")
    assert FleetStrategy.get(scope).draft == original
  end

  test "documents reject credential fields and incomplete Strategic Objectives" do
    scope = operator_fixture() |> Scope.for_operator()

    assert {:error, :invalid_document} =
             save_draft(
               scope,
               Map.put(document("Grow credits", "No scrap"), "account_token", "secret")
             )

    nested_credential =
      put_in(
        document("Grow credits", "No scrap"),
        ["objectives", Access.at(0), "evaluation"],
        %{"agent_token" => "secret"}
      )

    assert {:error, :invalid_document} = save_draft(scope, nested_credential)

    assert {:ok, _draft} =
             save_draft(scope, %{
               "objectives" => [%{"objective" => "Grow credits"}],
               "hard_constraints" => ["No scrap"],
               "preferences" => [],
               "consequences" => "Not yet specified"
             })

    assert {:error, :invalid_document} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
  end

  test "activation rejects a stale draft version" do
    scope = operator_fixture() |> Scope.for_operator()

    assert {:ok, first} = save_draft(scope, document("Grow credits", "No scrap"))

    assert {:ok, current} =
             save_draft(scope, document("Chart waypoints", "No scrap"))

    assert current.draft_version > first.draft_version
    assert {:error, :stale_draft} = FleetStrategy.activate(scope, first.draft_version)
    assert FleetStrategy.get(scope).active_revision == nil
  end

  test "draft edits and discard reject a stale draft version" do
    scope = operator_fixture() |> Scope.for_operator()
    original = document("Grow credits", "No scrap")
    current = document("Chart waypoints", "No scrap")

    assert {:ok, first} = save_draft(scope, original)
    assert {:ok, latest} = FleetStrategy.save_draft(scope, current, first.draft_version)

    assert {:error, :stale_draft} =
             FleetStrategy.save_draft(scope, original, first.draft_version)

    assert {:error, :stale_draft} =
             FleetStrategy.discard_draft(scope, first.draft_version)

    assert FleetStrategy.get(scope).draft == current
    assert FleetStrategy.get(scope).draft_version == latest.draft_version
  end

  test "attain, maintain, and continuous objectives expose purpose-appropriate evaluations" do
    revision = %Revision{
      id: 101,
      document: %{
        "objectives" => [
          objective("Map the system", "attain", "fleet_generation"),
          objective("Protect liquidity", "maintain", "recurring"),
          objective("Grow credits", "continuous", "strategy_lifetime")
        ]
      }
    }

    assert {:ok,
            %{
              objective_index: 0,
              kind: :attain,
              feasible?: true,
              progress: 0.4,
              remaining: 60,
              attained?: false,
              expected_seconds_to_target: 120
            }} =
             FleetStrategy.evaluate_objective(
               revision,
               0,
               %{current: 40, target: 100, expected_seconds_to_target: 120, feasible?: true}
             )

    assert {:ok, %{kind: :maintain, margin: 20, required_margin: 10, protected?: true}} =
             FleetStrategy.evaluate_objective(
               revision,
               1,
               %{current: 120, target: 100, required_margin: 10, feasible?: true}
             )

    assert {:ok, %{kind: :continuous, rate: 1_800.0, horizon_seconds: 3_600}} =
             FleetStrategy.evaluate_objective(
               revision,
               2,
               %{change: 30, elapsed_seconds: 60, horizon_seconds: 3_600, feasible?: true}
             )
  end

  test "a Server Reset clears Fleet Generation and recurring progress but retains Strategy-lifetime progress" do
    revision = %Revision{
      id: 102,
      document: %{
        "objectives" => [
          objective("Map the system", "attain", "fleet_generation"),
          objective("Grow total credits", "continuous", "strategy_lifetime"),
          objective("Fulfill contracts", "attain", "recurring")
        ]
      }
    }

    progress = %{
      revision_id: revision.id,
      fleet_generation_id: "generation-1",
      objectives: %{
        0 => %{progress: 0.8},
        1 => %{change: 250_000},
        2 => %{"contract-1" => %{progress: 0.5}}
      }
    }

    assert {:ok,
            %{
              revision_id: 102,
              fleet_generation_id: "generation-2",
              objectives: %{
                0 => nil,
                1 => %{change: 250_000},
                2 => %{recurrence_id: nil, progress: nil}
              }
            }} = FleetGeneration.advance_objective_progress(revision, progress, "generation-2")
  end

  test "recurring objectives reset only their own progress at a recurrence boundary" do
    revision = %Revision{
      id: 103,
      document: %{
        "objectives" => [
          objective("Grow total credits", "continuous", "strategy_lifetime"),
          objective("Fulfill contracts", "attain", "recurring")
        ]
      }
    }

    progress = %{
      revision_id: revision.id,
      fleet_generation_id: "generation-1",
      objectives: %{
        0 => %{change: 250_000},
        1 => %{recurrence_id: "contract-1", progress: %{delivered: 20}}
      }
    }

    assert {:ok,
            %{
              objectives: %{
                0 => %{change: 250_000},
                1 => %{recurrence_id: "contract-2", progress: nil}
              }
            }} = FleetStrategy.advance_recurrence(revision, progress, 1, "contract-2")

    assert {:error, :invalid_objective_progress} =
             FleetStrategy.advance_recurrence(revision, progress, -1, "contract-2")
  end

  test "ordered Strategic Priority is protected before Preferences rank admissible plans" do
    scope = operator_fixture() |> Scope.for_operator()

    document =
      document("Map the system", "Keep at least 50,000 credits available")
      |> Map.put("objectives", [
        objective("Map the system", "attain", "fleet_generation"),
        objective("Grow credits", "continuous", "recurring")
      ])

    revision = activate_document(scope, document)

    high_priority =
      plan(revision, :high_priority, 60, 5, [1], 60_000)

    preferred =
      plan(revision, :preferred, 90, 100, [2], 60_000)

    inadmissible =
      plan(revision, :inadmissible, 30, 1_000, [100], 40_000)

    assert {:ok,
            %{
              admissible: [%{id: :high_priority}, %{id: :preferred}],
              rejected: [%{plan: %{id: :inadmissible}, reasons: [reason]}]
            }} = FleetAllocation.rank_plans(scope, [preferred, inadmissible, high_priority])

    assert reason =~ "50,000 credit floor"

    equally_protected =
      plan(revision, :equally_protected, 60, 5, [2], 60_000)

    assert {:ok, %{admissible: [%{id: :equally_protected}, %{id: :high_priority}]}} =
             FleetAllocation.rank_plans(scope, [high_priority, equally_protected])
  end

  test "plans with incomplete or mismatched evaluations cannot yield to Preferences" do
    scope = operator_fixture() |> Scope.for_operator()
    revision = activate_document(scope, document("Grow credits", "No scrap"))

    incomplete = %{
      id: :incomplete,
      objective_evaluations: [],
      preference_evaluations: [],
      safety: safety_bounds(revision, %{scraps_ship: false})
    }

    {:ok, evaluation} =
      FleetStrategy.evaluate_objective(revision, 0, %{
        change: 10,
        elapsed_seconds: 10,
        horizon_seconds: 60,
        feasible?: true
      })

    complete = %{
      id: :complete,
      objective_evaluations: [evaluation],
      preference_evaluations: [preference_evaluation(revision, 0, 0)],
      safety: safety_bounds(revision, %{scraps_ship: false})
    }

    assert {:ok,
            %{
              admissible: [%{id: :complete}],
              rejected: [%{plan: %{id: :incomplete}, reasons: [reason]}]
            }} = FleetAllocation.rank_plans(scope, [incomplete, complete])

    assert reason =~ "complete matching evaluation"
  end

  test "activation rejects a Hard Constraint that Standing Authority cannot enforce" do
    scope = operator_fixture() |> Scope.for_operator()

    unenforceable =
      document("Grow credits", "Never pay more than 100 credits per unit of fuel")

    assert {:ok, _draft} = save_draft(scope, unenforceable)

    assert {:error, {:unenforceable_hard_constraint, constraint, explanation}} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert constraint == "Never pay more than 100 credits per unit of fuel"
    assert explanation =~ "SpaceTraders does not provide a conditional maximum price"
    assert FleetStrategy.get(scope).active_revision == nil
  end

  test "Standing Authority requires safety evidence for every Hard Constraint" do
    scope = operator_fixture() |> Scope.for_operator()
    document = document("Grow credits", "Keep at least 50,000 credits available")
    revision = activate_document(scope, document)

    assert {:ok, %{revision_id: revision_id, evidence_id: "evidence-1"}} =
             FleetStrategy.authorize(scope, safety_bounds(revision, %{minimum_credits: 50_000}))

    assert revision_id == revision.id

    assert {:error, [reason]} =
             FleetStrategy.authorize(scope, safety_bounds(revision, %{}))

    assert reason =~ "Cannot prove the 50,000 credit floor"
  end

  test "malformed constraints and consequence bounds are rejected conservatively" do
    scope = operator_fixture() |> Scope.for_operator()
    malformed = document("Grow credits", "Keep at least 1,,000 credits available")

    assert {:ok, _draft} = save_draft(scope, malformed)

    assert {:error, {:unenforceable_hard_constraint, _, explanation}} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert explanation =~ "No enforceable consequence rule"

    assert {:ok, _} = FleetStrategy.discard_draft(scope, FleetStrategy.get(scope).draft_version)
    revision = activate_document(scope, document("Grow credits", "No scrap"))

    assert {:error, [reason]} =
             FleetStrategy.authorize(scope, safety_bounds(revision, %{scraps_ship: :unknown}))

    assert reason =~ "Cannot prove that no Ship would be scrapped"
  end

  test "ranking rejects stale revision evidence and incomplete evaluation shapes" do
    scope = operator_fixture() |> Scope.for_operator()
    first = activate_document(scope, document("Grow credits", "No scrap"))

    {:ok, stale_evaluation} =
      FleetStrategy.evaluate_objective(first, 0, %{
        change: 10,
        elapsed_seconds: 10,
        horizon_seconds: 60,
        feasible?: true
      })

    assert {:ok, _draft} = save_draft(scope, document("Grow faster", "No scrap"))
    assert {:ok, current} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    stale_plan = %{
      id: :stale,
      objective_evaluations: [stale_evaluation],
      preference_evaluations: [preference_evaluation(first, 0, 1)],
      safety: safety_bounds(first, %{scraps_ship: false})
    }

    incomplete_plan = %{
      id: :incomplete,
      objective_evaluations: [
        %{revision_id: current.id, objective_index: 0, kind: :continuous, feasible?: true}
      ],
      preference_evaluations: [preference_evaluation(current, 0, 1)],
      safety: safety_bounds(current, %{scraps_ship: false})
    }

    assert {:ok, %{admissible: [], rejected: rejected, revision_id: revision_id}} =
             FleetAllocation.rank_plans(scope, [stale_plan, incomplete_plan, :malformed])

    assert revision_id == current.id
    assert length(rejected) == 3
    assert Enum.all?(rejected, fn rejection -> rejection.reasons != [] end)
  end

  defp document(objective, constraint) do
    %{
      "objectives" => [
        %{
          "objective" => objective,
          "kind" => "continuous",
          "evaluation" => "Measure progress",
          "scope" => "recurring"
        }
      ],
      "hard_constraints" => [constraint],
      "preferences" => ["Prefer efficient plans"],
      "consequences" => "The Fleet will pursue the listed outcomes within every Hard Constraint."
    }
  end

  defp objective(name, kind, scope) do
    %{
      "objective" => name,
      "kind" => kind,
      "evaluation" => "Measure progress",
      "scope" => scope
    }
  end

  defp plan(revision, id, expected_seconds, rate, preference_scores, minimum_credits) do
    {:ok, attain} =
      FleetStrategy.evaluate_objective(revision, 0, %{
        current: 0,
        target: 1,
        expected_seconds_to_target: expected_seconds,
        feasible?: true
      })

    {:ok, continuous} =
      FleetStrategy.evaluate_objective(revision, 1, %{
        change: rate,
        elapsed_seconds: 1,
        horizon_seconds: 1,
        feasible?: true
      })

    %{
      id: id,
      objective_evaluations: [attain, continuous],
      preference_evaluations:
        preference_scores
        |> Enum.with_index()
        |> Enum.map(fn {score, index} -> preference_evaluation(revision, index, score) end),
      safety: safety_bounds(revision, %{minimum_credits: minimum_credits})
    }
  end

  defp preference_evaluation(revision, index, score) do
    assert {:ok, evaluation} = FleetStrategy.evaluate_preference(revision, index, score)
    evaluation
  end

  defp safety_bounds(revision, bounds) do
    %{
      revision_id: revision.id,
      evidence_id: "evidence-1",
      observed_at: DateTime.utc_now(),
      bounds: bounds
    }
  end

  defp activate_document(scope, document) do
    assert {:ok, _draft} = save_draft(scope, document)
    assert {:ok, revision} = FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)
    revision
  end

  defp save_draft(scope, document) do
    FleetStrategy.save_draft(scope, document, FleetStrategy.get(scope).draft_version)
  end
end
