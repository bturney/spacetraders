defmodule SpaceTraders.FleetCapacityTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.Test.CapacityDispositions

  describe "proceed?/1" do
    test "only an explicit proceed disposition permits new governed work" do
      assert FleetCapacity.proceed?(CapacityDispositions.proceed())
      refute FleetCapacity.proceed?(CapacityDispositions.defer())
      refute FleetCapacity.proceed?(CapacityDispositions.unavailable())
      refute FleetCapacity.proceed?(nil)
      refute FleetCapacity.proceed?(%{available_slots: 10, backpressure: :none})
    end
  end

  describe "consumers" do
    # Authority precedes capacity: only the canonical current Fleet reaches
    # the Governor's disposition, so the consumer runs against a real one.
    setup do
      operator = SpaceTraders.AgentFixtures.operator_fixture()
      agent = SpaceTraders.AgentFixtures.agent_fixture(operator)
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
            "hard_constraints" => []
          },
          source: "operator",
          activated_at: DateTime.truncate(DateTime.utc_now(), :second)
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

      %{scope: Scope.for_operator(operator), agent: agent, revision: revision}
    end

    test "a caller without current-Fleet authority is refused before capacity is consulted" do
      assert {:error, :current_fleet_unavailable} =
               FleetExecution.reconcile_market_domain(
                 %Scope{operator: %{id: -1}},
                 %AgentRecord{id: -1},
                 %Revision{},
                 "X1",
                 nil
               )
    end

    for {label, disposition} <- [
          defer: quote(do: CapacityDispositions.defer()),
          unavailable: quote(do: CapacityDispositions.unavailable()),
          missing: nil
        ] do
      test "the Market pilot-domain decision is suppressed on #{label} capacity", ctx do
        assert {:ok, %{action: :deferred_for_capacity}} =
                 FleetExecution.reconcile_market_domain(
                   ctx.scope,
                   ctx.agent,
                   ctx.revision,
                   "X1",
                   unquote(disposition)
                 )
      end
    end
  end

  describe "disposition/2" do
    test "a missing governor reports unavailable rather than permission" do
      refute FleetCapacity.proceed?(
               SpaceTraders.API.CapacityGovernor.disposition(
                 SpaceTraders.API.OperationInventory.fetch!("get-market"),
                 %{strategic_priority: 0},
                 :no_such_governor
               )
             )
    end
  end
end
