defmodule SpaceTraders.MutationAttemptsTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API
  alias SpaceTraders.API.AgentTokenReference
  alias SpaceTraders.API.OperationInventory
  alias SpaceTraders.Fleet.{Intent, Ship}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.MutationAttempts
  alias SpaceTraders.SafetyFence

  test "a mutation is durable and sent-or-unknown before network dispatch" do
    operator = operator_fixture()
    agent = agent_fixture(operator, %{agent_token: "AGENT_TOKEN_SECRET"})
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

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

    ship =
      Repo.insert!(%Ship{agent_id: agent.id, symbol: agent.symbol, ship_type: "COMMAND_FRIGATE"})

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "manual",
        type: "navigate",
        target_waypoint: "X1-TEST-B2",
        in_flight_action: %{"kind" => "navigate"}
      })

    Req.Test.stub(API, fn conn ->
      assert [attempt] = MutationAttempts.list_for_agent(agent)
      assert attempt.state == "sent_or_unknown"
      assert attempt.fleet_generation_id == generation.id
      assert attempt.strategy_revision_id == revision.id
      assert attempt.provenance["ship_id"] == ship.id
      assert attempt.provenance["ship_symbol"] == ship.symbol
      assert attempt.provenance["intent_id"] == intent.id
      assert attempt.provenance["decision_episode_id"] == 17
      assert attempt.expected_effects == ["Ship nav and fuel response"]
      assert attempt.consequence_bounds == ["starts local transit"]

      assert attempt.prepared_evidence["preconditions"] == [
               "reachable destination",
               "sufficient fuel"
             ]

      refute inspect(attempt) =~ "AGENT_TOKEN_SECRET"

      Req.Test.json(conn, %{
        "data" => %{
          "fuel" => %{},
          "nav" => %{
            "systemSymbol" => "X1-TEST",
            "waypointSymbol" => "X1-TEST-B2",
            "status" => "IN_TRANSIT",
            "flightMode" => "CRUISE",
            "route" => %{}
          }
        }
      })
    end)

    result =
      SpaceTraders.Observability.with_context(
        [decision_episode_id: 17],
        fn ->
          API.navigate_ship(AgentTokenReference.new(agent), agent.symbol, "X1-TEST-B2")
        end
      )

    assert {:ok, %{}} = result
    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.state == "succeeded"
    assert attempt.operation_id == "navigate-ship"
    assert attempt.expected_effects == ["Ship nav and fuel response"]
    assert attempt.consequence_bounds == ["starts local transit"]
    assert [%{classification: "succeeded"}] = attempt.outcomes
    refute inspect(attempt) =~ "AGENT_TOKEN_SECRET"
  end

  test "an ambiguous attempt keeps its identity and evidence when reconciled" do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    Req.Test.stub(API, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    assert {:error, %API.Error{}} =
             API.navigate_ship(AgentTokenReference.new(agent), agent.symbol, "X1-TEST-B2")

    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.state == "ambiguous"
    assert [%{classification: "ambiguous"}] = attempt.outcomes

    assert {:error, %API.Error{reason: {:safety_fenced, [blocking_id]}}} =
             API.navigate_ship(AgentTokenReference.new(agent), agent.symbol, "X1-TEST-C3")

    assert blocking_id == attempt.id

    reloaded = MutationAttempts.get!(attempt.id)
    assert reloaded.id == attempt.id
    assert reloaded.state == "ambiguous"

    assert {:ok, reconciled} =
             MutationAttempts.reconcile(reloaded, :accepted, %{
               authoritative: true,
               source: "authoritative Ship state"
             })

    assert reconciled.id == attempt.id
    assert reconciled.state == "accepted"

    assert [ambiguous, reconciled_outcome] = reconciled.outcomes
    assert ambiguous.classification == "ambiguous"
    assert reconciled_outcome.classification == "accepted"
    assert reconciled_outcome.evidence["authoritative"]
  end

  test "an ambiguous Ship mutation fences only dependent Ship mutations" do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    ship_one =
      Repo.insert!(%Ship{agent_id: agent.id, symbol: "FENCE-1", ship_type: "COMMAND_FRIGATE"})

    ship_two =
      Repo.insert!(%Ship{agent_id: agent.id, symbol: "FENCE-2", ship_type: "PROBE"})

    operation = OperationInventory.fetch!("navigate-ship")

    assert {:ok, attempt} =
             MutationAttempts.prepare(operation, "/my/ships/#{ship_one.symbol}/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-B2"}
             )

    assert {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)

    assert {:ok, attempt} =
             MutationAttempts.record_outcome(attempt, :ambiguous, %{reason: "timeout"})

    assert SafetyFence.active?(attempt)

    assert {:error, {:safety_fenced, [blocking_id]}} =
             MutationAttempts.prepare(operation, "/my/ships/#{ship_one.symbol}/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-C3"}
             )

    assert blocking_id == attempt.id

    assert {:ok, unrelated_attempt} =
             MutationAttempts.prepare(operation, "/my/ships/#{ship_two.symbol}/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-C3"}
             )

    assert unrelated_attempt.dependency_keys != attempt.dependency_keys
  end

  test "reconciliation durably distinguishes accepted, absent, and Bounded Unknown outcomes" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    operation = OperationInventory.fetch!("navigate-ship")

    accepted = ambiguous_attempt(agent, operation, "OUTCOME-1")

    assert {:ok, accepted} =
             MutationAttempts.reconcile(accepted, :accepted, %{
               authoritative: true,
               source: "Ship state"
             })

    assert accepted.state == "accepted"
    refute SafetyFence.active?(accepted)
    assert List.last(accepted.outcomes).classification == "accepted"

    absent = ambiguous_attempt(agent, operation, "OUTCOME-2")

    assert {:ok, absent} =
             MutationAttempts.reconcile(
               absent,
               :absent,
               %{authoritative: true, source: "Ship state"},
               action_selected: true
             )

    assert absent.state == "absent"
    refute SafetyFence.active?(absent)
    assert List.last(absent.outcomes).classification == "absent"
    assert List.last(absent.outcomes).evidence["action_selected"]

    bounded_unknown = ambiguous_attempt(agent, operation, "OUTCOME-3")

    assert {:ok, bounded_unknown} =
             MutationAttempts.reconcile(bounded_unknown, :bounded_unknown, %{
               authoritative: true,
               consequence_bound: "at most one transit"
             })

    assert bounded_unknown.state == "bounded_unknown"
    assert SafetyFence.active?(bounded_unknown)
    assert List.last(bounded_unknown.outcomes).classification == "bounded_unknown"
  end

  test "retry requires authoritative absence, continued selection, and the same action" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    operation = OperationInventory.fetch!("navigate-ship")
    attempt = ambiguous_attempt(agent, operation, "RETRY-1", "X1-TEST-B2")

    assert {:error, :authoritative_evidence_required} =
             MutationAttempts.reconcile(
               attempt,
               :absent,
               %{source: "cached Ship state"},
               action_selected: true
             )

    assert {:ok, absent} =
             MutationAttempts.reconcile(
               attempt,
               :absent,
               %{authoritative: true, source: "fresh Ship state"},
               action_selected: true
             )

    assert {:error, :retry_action_mismatch} =
             MutationAttempts.prepare_retry(
               absent,
               operation,
               "/my/ships/RETRY-1/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-C3"}
             )

    assert {:ok, retry} =
             MutationAttempts.prepare_retry(
               absent,
               operation,
               "/my/ships/RETRY-1/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-B2"}
             )

    assert retry.retry_of_id == attempt.id

    assert {:error, :retry_not_authorized} =
             MutationAttempts.prepare_retry(
               absent,
               operation,
               "/my/ships/RETRY-1/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-B2"}
             )

    not_selected = ambiguous_attempt(agent, operation, "RETRY-2", "X1-TEST-D4")

    assert {:ok, not_selected} =
             MutationAttempts.reconcile(
               not_selected,
               :absent,
               %{authoritative: true, source: "fresh Ship state"},
               action_selected: false
             )

    assert {:error, :retry_not_authorized} =
             MutationAttempts.prepare_retry(
               not_selected,
               operation,
               "/my/ships/RETRY-2/navigate",
               agent_id: agent.id,
               json: %{"waypointSymbol" => "X1-TEST-D4"}
             )
  end

  test "a deterministic game rejection is retained as a rejected outcome" do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    Req.Test.stub(API, fn conn ->
      conn
      |> Map.put(:status, 400)
      |> Req.Test.json(%{"error" => %{"code" => 4204, "message" => "Ship is in transit"}})
    end)

    assert {:error, %API.GameplayError{code: 4204}} =
             API.navigate_ship(AgentTokenReference.new(agent), agent.symbol, "X1-TEST-B2")

    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.state == "rejected"
    assert [%{classification: "rejected", evidence: %{"status" => 400}}] = attempt.outcomes
  end

  test "an undecodable successful response remains ambiguous" do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    Req.Test.stub(API, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

    assert {:error, %API.Error{}} =
             API.navigate_ship(AgentTokenReference.new(agent), agent.symbol, "X1-TEST-B2")

    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.state == "ambiguous"

    assert [%{classification: "ambiguous", evidence: evidence}] = attempt.outcomes
    assert evidence == %{"reason" => "response_decode_failed", "status" => 200}
  end

  test "a body-carried Ship identity links execution provenance" do
    operator = operator_fixture()
    agent = agent_fixture(operator)

    ship =
      Repo.insert!(%Ship{agent_id: agent.id, symbol: "DELIVERY-1", ship_type: "LIGHT_HAULER"})

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "manual",
        type: "deliver",
        target_waypoint: "X1-TEST-A1",
        in_flight_action: %{"kind" => "deliver"}
      })

    Req.Test.stub(API, fn conn ->
      Req.Test.json(conn, %{"data" => %{"contract" => %{}, "cargo" => %{}}})
    end)

    assert {:ok, _result} =
             API.deliver_contract(
               AgentTokenReference.new(agent),
               "contract-1",
               ship.symbol,
               "IRON_ORE",
               5
             )

    assert [attempt] = MutationAttempts.list_for_agent(agent)
    assert attempt.provenance["ship_id"] == ship.id
    assert attempt.provenance["ship_symbol"] == ship.symbol
    assert attempt.provenance["intent_id"] == intent.id
  end

  test "registration evidence excludes credential values" do
    operator = operator_fixture()

    Req.Test.stub(API, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "token" => "NEW_AGENT_TOKEN_SECRET",
          "agent" => %{},
          "contract" => %{},
          "faction" => %{},
          "ships" => []
        }
      })
    end)

    assert {:ok, _registration} =
             SpaceTraders.Observability.with_context([operator_id: operator.id], fn ->
               API.register(
                 "ACCOUNT_TOKEN_SECRET",
                 "EVIDENCE",
                 "COSMIC",
                 operator.email
               )
             end)

    assert [attempt] = MutationAttempts.list_for_operator(operator)
    assert attempt.operation_id == "register"
    refute inspect(attempt) =~ "ACCOUNT_TOKEN_SECRET"
    refute inspect(attempt) =~ "NEW_AGENT_TOKEN_SECRET"
  end

  defp ambiguous_attempt(agent, operation, ship_symbol, destination \\ "X1-TEST-B2") do
    Repo.insert!(%Ship{agent_id: agent.id, symbol: ship_symbol, ship_type: "PROBE"})

    {:ok, attempt} =
      MutationAttempts.prepare(operation, "/my/ships/#{ship_symbol}/navigate",
        agent_id: agent.id,
        json: %{"waypointSymbol" => destination}
      )

    {:ok, attempt} = MutationAttempts.mark_sent_or_unknown(attempt)
    {:ok, attempt} = MutationAttempts.record_outcome(attempt, :ambiguous, %{reason: "timeout"})
    attempt
  end
end
