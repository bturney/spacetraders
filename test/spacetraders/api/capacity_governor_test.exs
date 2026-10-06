defmodule SpaceTraders.API.CapacityGovernorTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.CapacityGovernor

  defp unique_name, do: String.to_atom("capacity_governor_#{System.unique_integer([:positive])}")

  defp start_governor(opts \\ []) do
    name = unique_name()
    {:ok, pid} = CapacityGovernor.start_link([name: name] ++ opts)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    name
  end

  defp admission(id, lane \\ :standard) do
    %CapacityGovernor.Admission{
      id: id,
      operation_id: "get-my-agent",
      lane: lane,
      requested_at: DateTime.utc_now()
    }
  end

  test "admits safety reads ahead of an older standard read" do
    name = start_governor(max_in_flight: 1)

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
    name = start_governor(max_in_flight: 1)

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
    name = start_governor(max_in_flight: 1)

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
    name = start_governor(max_in_flight: 1)

    operation = SpaceTraders.API.OperationInventory.fetch!("navigate-ship")
    assert {:ok, %CapacityGovernor.Admission{}} = CapacityGovernor.admit(operation, %{}, name)

    test_pid = self()

    for _ <- 1..3 do
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
    end

    Process.sleep(10)

    GenServer.stop(Process.whereis(name))

    assert_receive {:stale_admission, :discarded}
    assert_receive {:stale_admission, :discarded}
    assert_receive {:stale_admission, :discarded}

    {:ok, _restarted} = CapacityGovernor.start_link(name: name, max_in_flight: 1)
    assert {:ok, %CapacityGovernor.Admission{}} = CapacityGovernor.admit(operation, %{}, name)
  end

  test "snapshot distinguishes normal, transient, and sustained protocol backpressure" do
    name = start_governor(max_in_flight: 3)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    snapshot = CapacityGovernor.snapshot(name)
    assert %CapacityGovernor.Snapshot{} = snapshot
    assert snapshot.backpressure == :none

    {:ok, first} = CapacityGovernor.admit(operation, %{}, name)
    {:ok, _second} = CapacityGovernor.admit(operation, %{}, name)
    queued = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    Process.sleep(10)

    CapacityGovernor.protocol_rejected(0, name)

    assert %CapacityGovernor.Snapshot{backpressure: :transient} = CapacityGovernor.snapshot(name)

    CapacityGovernor.protocol_rejected(0, name)

    assert %CapacityGovernor.Snapshot{backpressure: :sustained} = CapacityGovernor.snapshot(name)

    CapacityGovernor.complete(first, 200, name)
    {:ok, third} = Task.await(queued)
    CapacityGovernor.complete(third, 200, name)

    assert %CapacityGovernor.Snapshot{backpressure: :none} = CapacityGovernor.snapshot(name)
  end

  test "snapshot counts recent protocol rejections for calibration" do
    name = start_governor()

    CapacityGovernor.protocol_rejected(0, name)

    assert %CapacityGovernor.Snapshot{protocol_rejections: 1} = CapacityGovernor.snapshot(name)
  end

  test "Retry-After delays new ordinary admissions without starving protected lanes" do
    name = start_governor(max_in_flight: 1)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert {:ok, first} = CapacityGovernor.admit(operation, %{lane: :standard}, name)

    ordinary = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :standard}, name) end)
    safety = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :safety}, name) end)

    deadline =
      Task.async(fn ->
        CapacityGovernor.admit(operation, %{deadline_at: ~U[2030-01-01 00:00:00Z]}, name)
      end)

    Process.sleep(10)

    CapacityGovernor.protocol_rejected(1, name)

    assert %CapacityGovernor.Snapshot{ordinary_delayed_until: until} =
             CapacityGovernor.snapshot(name)

    assert until != nil

    CapacityGovernor.complete(first, 429, name)

    assert {:ok, %CapacityGovernor.Admission{lane: :safety} = safety_admission} =
             Task.await(safety)

    CapacityGovernor.complete(safety_admission, 200, name)

    assert {:ok, %CapacityGovernor.Admission{} = deadline_admission} = Task.await(deadline)
    CapacityGovernor.complete(deadline_admission, 200, name)

    # Ordinary demand releases when the Retry-After window closes.
    assert {:ok, %CapacityGovernor.Admission{}} = Task.await(ordinary, 10_000)
  end

  test "ordinary demand admitted after a rejection still releases when its window closes" do
    name = start_governor(max_in_flight: 1)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert {:ok, first} = CapacityGovernor.admit(operation, %{lane: :standard}, name)
    CapacityGovernor.protocol_rejected(1, name)
    CapacityGovernor.complete(first, 429, name)

    # Nothing was queued when the window opened, so admission below is the first
    # ordinary demand the Retry-After window applies to.
    later = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :standard}, name) end)

    assert {:ok, %CapacityGovernor.Admission{}} = Task.await(later, 10_000)
  end

  test "restart restores conservative admission that widens on clean outcomes" do
    name = start_governor(max_in_flight: 4)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert %CapacityGovernor.Snapshot{admitted_capacity: 2} = CapacityGovernor.snapshot(name)

    {:ok, first} = CapacityGovernor.admit(operation, %{}, name)
    {:ok, second} = CapacityGovernor.admit(operation, %{}, name)

    CapacityGovernor.complete(first, 200, name)
    assert %CapacityGovernor.Snapshot{admitted_capacity: 3} = CapacityGovernor.snapshot(name)

    CapacityGovernor.complete(second, 200, name)
    assert %CapacityGovernor.Snapshot{admitted_capacity: 4} = CapacityGovernor.snapshot(name)

    CapacityGovernor.protocol_rejected(0, name)
    assert %CapacityGovernor.Snapshot{admitted_capacity: 3} = CapacityGovernor.snapshot(name)

    {:ok, third} = CapacityGovernor.admit(operation, %{}, name)
    CapacityGovernor.complete(third, :unknown, name)

    assert %CapacityGovernor.Snapshot{admitted_capacity: 2, next_outage_probe_at: probe} =
             CapacityGovernor.snapshot(name)

    assert %DateTime{} = probe
  end

  test "emits admission telemetry measuring queue time and outcome telemetry for rejection and recovery" do
    name = start_governor(max_in_flight: 1)
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        "capacity-governor-test-#{System.unique_integer([:positive])}",
        [
          [:spacetraders, :api, :capacity, :governor],
          [:spacetraders, :api, :capacity, :reject],
          [:spacetraders, :api, :capacity, :recovered]
        ],
        fn event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert {:ok, first} = CapacityGovernor.admit(operation, %{lane: :standard}, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :governor], %{queue_time: q},
                    %{operation_id: "get-my-agent", lane: :standard}}

    assert q >= 0

    CapacityGovernor.protocol_rejected(0, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :reject],
                    %{count: 1, protocol_rejections: rejections}, %{ordinary_delayed: false}}

    assert rejections == 1

    CapacityGovernor.complete(first, 200, name)

    assert_receive {:telemetry, [:spacetraders, :api, :capacity, :recovered], %{count: 1},
                    %{recovery_ms: recovery}}

    assert recovery >= 0
  end

  defp release_and_await(first_id, waiting, name) do
    CapacityGovernor.complete(
      admission(first_id),
      200,
      name
    )

    Task.await(waiting)
  end
end
