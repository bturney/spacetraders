defmodule SpaceTraders.API.CapacityGovernorTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.CapacityGovernor

  test "admits safety reads ahead of an older standard read" do
    name = unique_name()
    {:ok, pid} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert {:ok, %CapacityGovernor.Admission{id: first_id}} =
             CapacityGovernor.admit(operation, %{lane: :standard}, name)

    standard = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :standard}, name) end)
    safety = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :safety}, name) end)
    Process.sleep(10)

    assert {:ok, %CapacityGovernor.Admission{lane: :safety} = safety_admission} =
             release_and_await(first_id, safety, name)

    CapacityGovernor.complete(safety_admission, 200, name)
    assert {:ok, %CapacityGovernor.Admission{lane: :standard}} = Task.await(standard)
  end

  defp release_and_await(first_id, safety, name) do
    CapacityGovernor.complete(
      %CapacityGovernor.Admission{
        id: first_id,
        operation_id: "get-my-agent",
        lane: :standard,
        requested_at: DateTime.utc_now()
      },
      200,
      name
    )

    Task.await(safety)
  end

  defp unique_name, do: String.to_atom("capacity_governor_#{System.unique_integer([:positive])}")
end
