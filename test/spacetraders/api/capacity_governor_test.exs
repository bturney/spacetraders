defmodule SpaceTraders.API.CapacityGovernorTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.API.CapacityGovernor

  # #585/#579 approve the isolated governor's disposition and live admission
  # seams. Advisory checks must never hold a slot or authorize gameplay.
  test "advisory proceed reserves nothing and live contention still delays admission" do
    name = start_governor(max_in_flight: 1)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")

    assert %{status: :proceed, reason: :capacity_available, retry_at: nil} =
             CapacityGovernor.disposition(operation, %{}, name)

    assert %{status: :proceed} = CapacityGovernor.disposition(operation, %{}, name)
    assert {:ok, held} = CapacityGovernor.admit(operation, %{}, name)

    assert %{status: :defer, reason: :contention, retry_at: %DateTime{}} =
             CapacityGovernor.disposition(operation, %{}, name)

    waiting = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    assert Task.yield(waiting, 20) == nil
    CapacityGovernor.complete(held, 200, name)
    assert {:ok, %CapacityGovernor.Admission{}} = Task.await(waiting)
  end

  defp unique_name, do: String.to_atom("capacity_governor_#{System.unique_integer([:positive])}")

  test "live admission withholds Retry-After-deferred ordinary work that an arbitrary lane cannot unlock" do
    name = start_governor(max_in_flight: 2)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")
    CapacityGovernor.protocol_rejected(30, name)

    invented = Task.async(fn -> CapacityGovernor.admit(operation, %{lane: :invented}, name) end)
    assert Task.yield(invented, 20) == nil

    assert {:ok, %CapacityGovernor.Admission{lane: :reconciliation}} =
             CapacityGovernor.admit(operation, %{purpose: :recovery}, name)

    Task.shutdown(invented, :brutal_kill)
  end

  test "owner priority outranks value and value breaks ties without timestamp protection" do
    name = start_governor(max_in_flight: 1)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")
    {:ok, held} = CapacityGovernor.admit(operation, %{}, name)

    attrs = [
      %{strategic_priority: 2, expected_value: 1000, deadline_at: ~U[2030-01-01 00:00:00Z]},
      %{strategic_priority: 1, expected_value: 10},
      %{strategic_priority: 1, expected_value: 20}
    ]

    [low_priority, low_value, high_value] =
      Enum.with_index(attrs, 1)
      |> Enum.map(fn {context, count} ->
        task = Task.async(fn -> CapacityGovernor.admit(operation, context, name) end)
        await_queue(name, count)
        task
      end)

    CapacityGovernor.complete(held, 200, name)
    assert {:ok, first} = Task.await(high_value)
    assert Task.yield(low_priority, 0) == nil
    CapacityGovernor.complete(first, 200, name)
    assert {:ok, second} = Task.await(low_value)
    CapacityGovernor.complete(second, 200, name)
    assert {:ok, _} = Task.await(low_priority)
  end

  defp await_queue(name, count, tries \\ 1000)
  defp await_queue(_name, _count, 0), do: flunk("governor did not queue the caller")

  defp await_queue(name, count, tries) do
    if length(:sys.get_state(name).queue) != count do
      receive do
      after
        1 -> await_queue(name, count, tries - 1)
      end
    end
  end

  test "missing authority is unavailable while intentional test disabling is distinct" do
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")
    missing = unique_name()

    assert %{status: :unavailable, reason: :authority_unavailable, retry_at: %DateTime{}} =
             CapacityGovernor.disposition(operation, %{}, missing)

    assert {:error, :capacity_unavailable} = CapacityGovernor.admit(operation, %{}, missing)
    assert {:ok, nil} = CapacityGovernor.admit(operation, %{}, :test_disabled)

    assert %{status: :proceed, reason: :test_disabled} =
             CapacityGovernor.disposition(operation, %{}, :test_disabled)
  end

  test "Retry-After guidance uses recognized purpose, never arbitrary lanes or timestamps" do
    now = ~U[2026-10-05 12:00:00Z]
    name = start_governor(now: fn -> now end)
    operation = SpaceTraders.API.OperationInventory.fetch!("get-my-agent")
    CapacityGovernor.protocol_rejected(30, name)

    for attrs <- [%{}, %{lane: :invented}, %{deadline_at: DateTime.add(now, 1)}] do
      assert %{status: :defer, reason: :retry_after, observed_at: ^now, retry_at: retry} =
               CapacityGovernor.disposition(operation, attrs, name)

      assert retry == ~U[2026-10-05 12:00:30Z]
    end

    for attrs <- [
          %{purpose: :safety},
          %{purpose: :recovery},
          %{lane: :reconciliation},
          %{purpose: :deadline_critical, deadline_at: DateTime.add(now, 1)}
        ] do
      assert %{status: :proceed} = CapacityGovernor.disposition(operation, attrs, name)
    end

    assert %{status: :defer} =
             CapacityGovernor.disposition(operation, %{purpose: :deadline_critical}, name)
  end

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
        CapacityGovernor.admit(
          operation,
          %{purpose: :deadline_critical, deadline_at: ~U[2030-01-01 00:00:00Z]},
          name
        )
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
          send(test_pid, {:stale_admission, CapacityGovernor.admit(operation, %{}, name)})
        end)
    end

    Process.sleep(10)

    GenServer.stop(Process.whereis(name))

    assert_receive {:stale_admission, {:error, :capacity_unavailable}}
    assert_receive {:stale_admission, {:error, :capacity_unavailable}}
    assert_receive {:stale_admission, {:error, :capacity_unavailable}}

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
        CapacityGovernor.admit(
          operation,
          %{purpose: :deadline_critical, deadline_at: ~U[2030-01-01 00:00:00Z]},
          name
        )
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
