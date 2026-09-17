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

  test "admits reconciliation mutations ahead of older standard gameplay" do
    name = unique_name()
    {:ok, pid} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    standard = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")
    reconciliation = SpaceTraders.API.OperationInventory.fetch!("accept-contract")

    assert {:ok, %CapacityGovernor.Admission{id: first_id}} =
             CapacityGovernor.admit(standard, %{}, name)

    gameplay = Task.async(fn -> CapacityGovernor.admit(standard, %{}, name) end)
    recovery = Task.async(fn -> CapacityGovernor.admit(reconciliation, %{}, name) end)
    Process.sleep(10)

    assert {:ok, %CapacityGovernor.Admission{lane: :reconciliation} = recovery_admission} =
             release_and_await(first_id, recovery, name)

    CapacityGovernor.complete(recovery_admission, 200, name)
    assert {:ok, %CapacityGovernor.Admission{lane: :standard}} = Task.await(gameplay)
  end

  test "admits deadline-critical gameplay ahead of older standard gameplay" do
    name = unique_name()
    {:ok, pid} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    operation = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")

    assert {:ok, %CapacityGovernor.Admission{id: first_id}} =
             CapacityGovernor.admit(operation, %{}, name)

    gameplay = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)

    deadline =
      Task.async(fn ->
        CapacityGovernor.admit(operation, %{deadline_at: ~U[2030-01-01 00:00:00Z]}, name)
      end)

    Process.sleep(10)

    assert {:ok, %CapacityGovernor.Admission{} = deadline_admission} =
             release_and_await(first_id, deadline, name)

    CapacityGovernor.complete(deadline_admission, 200, name)
    assert {:ok, %CapacityGovernor.Admission{lane: :standard}} = Task.await(gameplay)
  end

  test "does not retain queued work after governor recovery" do
    name = unique_name()
    {:ok, pid} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    on_exit(fn -> if governor = Process.whereis(name), do: GenServer.stop(governor) end)

    operation = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")
    assert {:ok, %CapacityGovernor.Admission{}} = CapacityGovernor.admit(operation, %{}, name)

    test_pid = self()

    {:ok, _stale} =
      Task.start(fn ->
        result =
          try do
            CapacityGovernor.admit(operation, %{}, name)
          catch
            :exit, _reason -> :discarded
          end

        send(test_pid, {:stale_admission, result})
      end)

    Process.sleep(10)

    GenServer.stop(pid)
    assert_receive {:stale_admission, :discarded}

    {:ok, _restarted} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    assert {:ok, %CapacityGovernor.Admission{}} = CapacityGovernor.admit(operation, %{}, name)
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
