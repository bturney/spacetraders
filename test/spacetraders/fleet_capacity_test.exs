defmodule SpaceTraders.FleetCapacityTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetExecution
  alias SpaceTraders.FleetIntelligence
  alias SpaceTraders.FleetStrategy.Revision
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
    for {label, disposition} <- [
          defer: quote(do: CapacityDispositions.defer()),
          unavailable: quote(do: CapacityDispositions.unavailable()),
          missing: nil
        ] do
      test "intelligence activation is suppressed on #{label} capacity" do
        assert {:error, :api_capacity_unavailable} =
                 FleetExecution.activate_intelligence(
                   %Scope{},
                   %AgentRecord{},
                   %Revision{},
                   %{candidate_contributions: [], observation_demands: []},
                   unquote(disposition)
                 )
      end

      test "intelligence reconciliation is suppressed on #{label} capacity" do
        assert {:error, :no_decision_relevant_intelligence} =
                 FleetIntelligence.reconcile(
                   %Scope{},
                   %AgentRecord{},
                   %Revision{},
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
