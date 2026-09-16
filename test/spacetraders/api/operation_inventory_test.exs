defmodule SpaceTraders.API.OperationInventoryTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.OperationInventory

  @spec_path "priv/spec/SpaceTraders.json"

  test "classifies every pinned operation exactly once with complete metadata" do
    operations = OperationInventory.all()
    operation_ids = Enum.map(operations, & &1.id)

    assert length(operation_ids) == length(Enum.uniq(operation_ids))
    assert MapSet.new(operation_ids) == pinned_operation_ids()
    assert Enum.count(operations, &(&1.classification == :read)) == 26
    assert Enum.count(operations, &(&1.classification == :mutation)) == 33

    for operation <- operations do
      assert %OperationInventory.Operation{} = operation
      assert operation.classification in [:read, :mutation]

      assert operation.owner in [
               :evidence,
               :fleet_generation,
               :fleet_reconciliation,
               :ship_execution
             ]

      assert operation.prerequisites != []
      assert operation.consequences != []
      assert operation.success_evidence != []
      assert operation.waits in [:none, :cooldown, :transit]
      assert operation.ambiguity in [:safe_retry, :reconcile_before_retry]
      assert operation.visibility in [:public, :agent, :ship_local, :location_dependent]
      assert operation.pagination in [:none, :page_limit]
    end
  end

  test "reads and mutations have the required governance metadata" do
    for operation <- OperationInventory.all() do
      case operation.classification do
        :read ->
          assert operation.owner == :evidence
          assert operation.ambiguity == :safe_retry

        :mutation ->
          assert operation.owner in [:fleet_generation, :fleet_reconciliation, :ship_execution]
          assert operation.ambiguity == :reconcile_before_retry
      end
    end
  end

  defp pinned_operation_ids do
    @spec_path
    |> File.read!()
    |> Jason.decode!()
    |> Map.fetch!("paths")
    |> Enum.flat_map(fn {_path, methods} ->
      methods
      |> Map.take(["get", "post", "patch", "put", "delete"])
      |> Map.values()
      |> Enum.map(&Map.fetch!(&1, "operationId"))
    end)
    |> MapSet.new()
  end
end
