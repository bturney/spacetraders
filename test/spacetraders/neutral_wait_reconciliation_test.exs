defmodule SpaceTraders.NeutralWaitReconciliationTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.API.CapacityGovernor.Snapshot, as: CapacitySnapshot
  alias SpaceTraders.API.Model.Waypoint
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Clock, Evidence, FleetAllocation, FleetExecution, Intelligence}
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.FleetAllocation.{AllocationResultPointer, StrategyDecisionEpisode}
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}

  @system "X1-UX81"
  @waypoint "X1-UX81-A1"
  @market_subject "market:X1-UX81:X1-UX81-A1"

  setup do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    as_of = Clock.utc_now()

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
              "evaluation" => "Maximize net credit growth over time"
            }
          ],
          "hard_constraints" => [%{"kind" => "credit_floor", "minimum" => 1_000}]
        },
        source: "operator",
        activated_at: DateTime.truncate(as_of, :second)
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

    ship =
      Repo.insert!(%Ship{
        symbol: "#{agent.symbol}-1",
        ship_type: "SHIP_FRIGATE",
        agent_id: agent.id
      })

    observe_market(agent, as_of)
    stub_availability(ship, %{"symbol" => agent.symbol, "credits" => 10_000})

    capacity = %CapacitySnapshot{
      observed_at: as_of,
      available_slots: 10,
      evidence_fingerprint: "neutral-wait-reconciliation",
      backpressure: :normal
    }

    %{
      agent: agent,
      scope: scope,
      revision: revision,
      generation: generation,
      ship: ship,
      capacity: capacity
    }
  end

  test "zero admissible contributions with future due evidence create one durable Neutral Wait",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         capacity: capacity
       } do
    demand = request_market_demand(agent, revision, DateTime.add(capacity.observed_at, 300))

    assert {:ok, %{action: :no_admissible_commitment, comparison: %{proposed_choices: []}}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    # Durable identity and current-result linkage are the persistence contract.
    assert [%StrategyDecisionEpisode{} = episode] = decision_episodes(generation)
    assert episode.selection_kind == :neutral_wait
    assert episode.classification == :still_evaluating
    assert episode.fleet_strategy_revision_id == revision.id
    assert episode.binding_limitation_kind == :no_admissible_candidate
    assert episode.next_observation_at == demand.due_at

    assert %{
             "kind" => "observation_demand",
             "id" => demand.id,
             "subject" => @market_subject,
             "due_at" => DateTime.to_iso8601(demand.due_at)
           } in episode.evidence_references

    pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
    assert pointer.selection_kind == :neutral_wait
    assert pointer.strategy_decision_episode_id == episode.id
    assert FleetAllocation.current_neutral_wait_since(generation.id) == episode.inserted_at
    assert FleetAllocation.current_portfolio(scope, agent) == nil
  end

  test "equivalent reconciliation retains the episode while refreshing its future evidence",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         capacity: capacity
       } do
    demand = request_market_demand(agent, revision, DateTime.add(capacity.observed_at, 300))

    assert {:ok, %{action: :no_admissible_commitment}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert [original] = decision_episodes(generation)

    assert {:ok, %{action: :no_admissible_commitment}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert [%{id: same_id}] = decision_episodes(generation)
    assert same_id == original.id

    assert {:ok, replacement} =
             Evidence.replace_demand(demand, %{due_at: DateTime.add(capacity.observed_at, 600)})

    assert {:ok, %{action: :no_admissible_commitment}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert [refreshed] = decision_episodes(generation)
    assert refreshed.id == original.id
    assert refreshed.selection_kind == :neutral_wait
    assert refreshed.classification == :still_evaluating
    assert refreshed.binding_limitation_kind == original.binding_limitation_kind
    assert refreshed.next_observation_at == replacement.due_at
    assert FleetAllocation.current_neutral_wait_since(generation.id) == original.inserted_at
    assert FleetAllocation.current_portfolio(scope, agent) == nil

    assert Enum.any?(refreshed.evidence_references, fn reference ->
             reference["kind"] == "observation_demand" and reference["id"] == replacement.id
           end)

    pointer = Repo.get_by!(AllocationResultPointer, fleet_generation_id: generation.id)
    assert pointer.strategy_decision_episode_id == original.id
  end

  test "zero admissible contributions without durable future evidence do not create a wait",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         capacity: capacity
       } do
    assert {:ok, %{action: :no_admissible_commitment}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert_no_wait(scope, agent, generation)

    _already_due = request_market_demand(agent, revision, capacity.observed_at)

    assert {:ok, %{action: :no_admissible_commitment}} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert_no_wait(scope, agent, generation)
  end

  test "unknown Governed Availability stays distinct even with future due evidence",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         ship: ship,
         capacity: capacity
       } do
    _demand = request_market_demand(agent, revision, DateTime.add(capacity.observed_at, 300))

    stub_availability(ship, %{"symbol" => agent.symbol})

    assert {:error, :availability_unknown} =
             FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, capacity)

    assert_no_wait(scope, agent, generation)
  end

  test "API-capacity deferral stays distinct even with future due evidence",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         capacity: capacity
       } do
    _demand = request_market_demand(agent, revision, DateTime.add(capacity.observed_at, 300))

    for deferred <- [
          %{capacity | available_slots: 0},
          %{capacity | backpressure: :sustained}
        ] do
      assert {:ok, %{action: :deferred_for_capacity}} =
               FleetExecution.reconcile_market_evidence(scope, agent, revision, @system, deferred)

      assert_no_wait(scope, agent, generation)
    end
  end

  test "objective infeasibility reports its own outcome without creating a Neutral Wait",
       %{
         agent: agent,
         scope: scope,
         revision: revision,
         generation: generation,
         ship: ship,
         capacity: capacity
       } do
    _demand = request_market_demand(agent, revision, DateTime.add(capacity.observed_at, 300))
    ship_symbol = ship.symbol

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "fleet_allocation:#{agent.operator_id}")

    assert {:ok, :ok} =
             FleetAllocation.report_infeasibility(
               agent,
               ship_symbol,
               %{
                 "kind" => "objective_infeasibility",
                 "subject" => @market_subject,
                 "reason" => "destination_unreachable"
               },
               fn -> :ok end
             )

    assert_receive {:outbox, _notification_id, "ship_execution_infeasible",
                    %{
                      "ship_symbol" => ^ship_symbol,
                      "kind" => "objective_infeasibility",
                      "subject" => @market_subject,
                      "reason" => "destination_unreachable"
                    }}

    assert_no_wait(scope, agent, generation)
  end

  defp assert_no_wait(scope, agent, generation) do
    assert decision_episodes(generation) == []
    assert Repo.get_by(AllocationResultPointer, fleet_generation_id: generation.id) == nil
    assert FleetAllocation.current_neutral_wait_since(generation.id) == nil
    assert FleetAllocation.current_portfolio(scope, agent) == nil
  end

  defp request_market_demand(agent, revision, due_at) do
    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: @market_subject,
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: due_at,
               owner: "fleet_planning"
             })

    demand
  end

  defp decision_episodes(generation) do
    Repo.all(
      from episode in StrategyDecisionEpisode,
        where: episode.fleet_generation_id == ^generation.id
    )
  end

  defp observe_market(agent, as_of) do
    waypoint =
      Waypoint.from_json(%{
        "symbol" => @waypoint,
        "systemSymbol" => @system,
        "type" => "PLANET",
        "x" => 1,
        "y" => 2,
        "traits" => [%{"symbol" => "MARKETPLACE"}]
      })

    assert {:ok, _} =
             Intelligence.observe_waypoint(agent, waypoint,
               source: "get_waypoint",
               observed_at: as_of
             )

    # Complete coverage of the known Marketplace has no profitable route.
    observation =
      Evidence.authoritative_observation(
        "get-market",
        [@market_subject],
        %{
          trade_goods: [
            %{
              symbol: "IRON_ORE",
              purchase_price: 12,
              sell_price: 9,
              trade_volume: 20,
              supply: "MODERATE",
              activity: "STATIC"
            }
          ]
        },
        as_of
      )

    assert {:ok, _} = Evidence.fulfil_demands(agent, @market_subject, observation, as_of)
  end

  defp stub_availability(ship, agent_payload) do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v2/my/ships"} ->
          Req.Test.json(conn, %{"data" => [ship_body(ship.symbol)]})

        {"GET", "/v2/my/agent"} ->
          Req.Test.json(conn, %{"data" => agent_payload})

        other ->
          flunk("unexpected SpaceTraders request: #{inspect(other)}")
      end
    end)
  end
end
