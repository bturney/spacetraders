defmodule SpaceTraders.FleetCapacityTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.FleetCapacity
  alias SpaceTraders.FleetExecution
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
      test "the Market pilot-domain decision is suppressed on #{label} capacity" do
        assert {:ok, %{action: :deferred_for_capacity}} =
                 FleetExecution.reconcile_market_domain(
                   %Scope{operator: %{id: -1}},
                   %AgentRecord{id: -1},
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
