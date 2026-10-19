defmodule SpaceTraders.API.SemanticCapacityTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.{Clock, TestClock}
  alias SpaceTraders.API.{CapacityGovernor, OperationInventory, RateLimiter}

  setup do
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({TestClock, ~U[2026-10-19 00:00:00.000000Z]})
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    :ok
  end

  test "a pre-restart completion cannot release a new admission with the same sequence" do
    name = :semantic_restart_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("navigate-ship")
    {:ok, old} = CapacityGovernor.admit(operation, %{}, name)
    stop_supervised!(CapacityGovernor)
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    {:ok, current} = CapacityGovernor.admit(operation, %{}, name)
    refute old.id == current.id
    CapacityGovernor.complete(old, 200, name)

    assert %{status: :defer, reason: :contention} =
             CapacityGovernor.disposition(operation, %{}, name)

    CapacityGovernor.complete(current, 200, name)
    assert %{status: :proceed} = CapacityGovernor.disposition(operation, %{}, name)
  end

  test "protocol scarcity owns an exact semantic release and repeated checks gift no tokens" do
    name = :semantic_limiter
    start_supervised!({RateLimiter, name: name, burst: 1, pool_burst: 0, rate: 2.0})
    assert :ok = RateLimiter.try_acquire(name)

    for _ <- 1..3 do
      assert {:defer, ~U[2026-10-19 00:00:00.500000Z]} = RateLimiter.try_acquire(name)
    end

    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:00.500000Z]
    TestClock.advance(499, :millisecond)
    assert {:defer, ~U[2026-10-19 00:00:00.500000Z]} = RateLimiter.try_acquire(name)
    TestClock.advance(1, :millisecond)
    assert :ok = RateLimiter.try_acquire(name)
    assert {:defer, ~U[2026-10-19 00:00:01.000000Z]} = RateLimiter.try_acquire(name)
  end

  test "outage retries are one bounded probe and failed probes own later semantic releases" do
    name = :semantic_outage_governor
    start_supervised!({CapacityGovernor, name: name, probe_base_ms: 1_000})

    for id <- ["get-market", "get-my-ship"] do
      {:ok, admission} = CapacityGovernor.admit(OperationInventory.fetch!(id), %{}, name)
      CapacityGovernor.complete(admission, 503, name)
    end

    operation = OperationInventory.fetch!("get-my-agent")

    assert {:defer, %{reason: :outage, retry_at: ~U[2026-10-19 00:00:01.000000Z]}} =
             CapacityGovernor.try_admit(operation, %{purpose: :safety}, name)

    TestClock.advance(999, :millisecond)
    assert {:defer, %{reason: :outage}} = CapacityGovernor.try_admit(operation, %{}, name)
    TestClock.advance(1, :millisecond)
    {:ok, probe} = CapacityGovernor.try_admit(operation, %{}, name)
    assert {:defer, %{reason: :outage}} = CapacityGovernor.try_admit(operation, %{}, name)
    CapacityGovernor.complete(probe, 503, name)

    assert {:defer, %{retry_at: ~U[2026-10-19 00:00:03.000000Z]}} =
             CapacityGovernor.try_admit(operation, %{}, name)

    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:03.000000Z]
    TestClock.advance(2)
    {:ok, probe} = CapacityGovernor.try_admit(operation, %{}, name)
    CapacityGovernor.complete(probe, 200, name)
    assert %{status: :proceed} = CapacityGovernor.disposition(operation, %{}, name)
  end

  test "queued admission releases at the semantic Retry-After boundary, never one millisecond early" do
    name = :semantic_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-my-agent")
    CapacityGovernor.protocol_rejected(5, name)

    assert %{retry_at: ~U[2026-10-19 00:00:05.000000Z]} =
             CapacityGovernor.disposition(operation, %{}, name)

    caller = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    # The supported barrier orders preceding governor messages; diagnostic counts
    # synchronize this external caller without inspecting process state.
    await_queue(name)
    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:05.000000Z]
    TestClock.advance(4_999, :millisecond)
    assert Task.yield(caller, 0) == nil
    TestClock.advance(1, :millisecond)

    assert {:ok, %{requested_at: ~U[2026-10-19 00:00:00.000000Z]} = admission} =
             Task.await(caller)

    CapacityGovernor.complete(admission, 200, name)

    assert %{status: :proceed, observed_at: now} =
             CapacityGovernor.disposition(operation, %{}, name)

    assert now == Clock.utc_now()
  end

  test "queued native admission re-wakes for later overlapping outage and Retry-After boundaries" do
    name = :overlapping_outage_governor
    start_supervised!({CapacityGovernor, name: name, probe_base_ms: 1_000})

    for id <- ["get-market", "get-my-ship"] do
      {:ok, admission} = CapacityGovernor.admit(OperationInventory.fetch!(id), %{}, name)
      CapacityGovernor.complete(admission, 503, name)
    end

    CapacityGovernor.protocol_rejected(5, name)
    operation = OperationInventory.fetch!("get-status")
    caller = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    await_queue(name)
    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:01.000000Z]
    TestClock.advance(1)
    assert %{in_flight: 0} = CapacityGovernor.diagnostics(name)
    assert Task.yield(caller, 0) == nil
    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:05.000000Z]
    TestClock.advance(3_999, :millisecond)
    assert Task.yield(caller, 0) == nil
    TestClock.advance(1, :millisecond)
    assert {:ok, admission} = Task.await(caller)
    CapacityGovernor.complete(admission, 200, name)
  end

  test "queued native admission re-wakes for a scoped boundary after protocol pressure releases" do
    name = :overlapping_scoped_governor
    start_supervised!({CapacityGovernor, name: name, probe_base_ms: 5_000})
    operation = OperationInventory.fetch!("get-market")
    {:ok, failed} = CapacityGovernor.admit(operation, %{}, name)
    CapacityGovernor.complete(failed, 503, name)
    CapacityGovernor.protocol_rejected(1, name)
    caller = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    await_queue(name)
    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:01.000000Z]
    TestClock.advance(1)
    assert %{in_flight: 0} = CapacityGovernor.diagnostics(name)
    assert Task.yield(caller, 0) == nil
    assert TestClock.next_due_at() == ~U[2026-10-19 00:00:05.000000Z]
    TestClock.advance(4)
    assert {:ok, admission} = Task.await(caller)
    CapacityGovernor.complete(admission, 200, name)
  end

  test "deferred semantic competitors keep governor ordering instead of retry callback order" do
    name = :ordered_semantic_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-status")
    {:ok, held} = CapacityGovernor.admit(operation, %{}, name)
    # Register worst-first. Protection, priority, deadline and value each beat
    # the order in which callbacks later ask to consume the free slot.
    [low, low_value, high_value, deadline, recovery] =
      competitors = [
        %{request_key: :low, strategic_priority: 2, expected_value: 1000},
        %{request_key: :low_value, strategic_priority: 1, expected_value: 10},
        %{request_key: :high_value, strategic_priority: 1, expected_value: 20},
        %{request_key: :deadline, strategic_priority: 1, deadline_at: ~U[2026-10-19 00:01:00Z]},
        %{request_key: :recovery, purpose: :recovery}
      ]

    for attrs <- competitors do
      assert {:defer, _} = CapacityGovernor.try_admit(operation, attrs, name)
    end

    CapacityGovernor.complete(held, 200, name)

    for {winner, waiting} <- [
          {recovery, [low, low_value, high_value, deadline]},
          {deadline, [low, low_value, high_value]},
          {high_value, [low, low_value]},
          {low_value, [low]},
          {low, []}
        ] do
      assert %{in_flight: 0} = CapacityGovernor.diagnostics(name)

      for attrs <- waiting do
        assert {:defer, _} = CapacityGovernor.try_admit(operation, attrs, name)
      end

      assert {:ok, admission} = CapacityGovernor.try_admit(operation, winner, name)
      assert admission.requested_at == ~U[2026-10-19 00:00:00.000000Z]
      assert %{in_flight: 1} = CapacityGovernor.diagnostics(name)
      CapacityGovernor.complete(admission, 200, name)
    end

    assert %{deferred: %{}} = CapacityGovernor.diagnostics(name)
  end

  test "pending demand deduplicates, renews, keeps FIFO and can be cancelled without holding capacity" do
    name = :pending_lifecycle_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-status")
    {:ok, held} = CapacityGovernor.admit(operation, %{}, name)
    first = %{request_key: :first}
    second = %{request_key: :second}
    for _ <- 1..3, do: assert({:defer, _} = CapacityGovernor.try_admit(operation, first, name))
    assert {:defer, _} = CapacityGovernor.try_admit(operation, second, name)
    assert %{deferred: %{standard: %{count: 2}}} = CapacityGovernor.diagnostics(name)
    TestClock.advance(64)
    assert {:defer, _} = CapacityGovernor.try_admit(operation, first, name)
    CapacityGovernor.complete(held, 200, name)
    assert {:defer, _} = CapacityGovernor.try_admit(operation, second, name)
    assert %{in_flight: 0} = CapacityGovernor.diagnostics(name)
    assert :ok = CapacityGovernor.cancel_pending(operation, first, name)
    assert {:ok, winner} = CapacityGovernor.try_admit(operation, second, name)
    assert winner.requested_at == ~U[2026-10-19 00:00:00.000000Z]
    CapacityGovernor.complete(winner, 200, name)
    assert %{deferred: %{}} = CapacityGovernor.diagnostics(name)
    assert TestClock.next_due_at() == nil
  end

  test "abandoned pending demand expires and releases native queued work without a phantom admission" do
    name = :pending_expiry_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-status")
    {:ok, held} = CapacityGovernor.admit(operation, %{}, name)
    assert {:defer, _} = CapacityGovernor.try_admit(operation, %{purpose: :recovery}, name)
    CapacityGovernor.complete(held, 200, name)
    caller = Task.async(fn -> CapacityGovernor.admit(operation, %{}, name) end)
    await_queue(name, 2)
    assert %{in_flight: 0, admitted_capacity: 1} = CapacityGovernor.diagnostics(name)
    TestClock.advance(64_999, :millisecond)
    assert Task.yield(caller, 0) == nil
    TestClock.advance(1, :millisecond)
    assert {:ok, admission} = Task.await(caller)
    assert admission.lane == :standard
    assert %{deferred: %{}} = CapacityGovernor.diagnostics(name)
  end

  test "owner death discards pending priority and governor restart never replays pending demand" do
    name = :pending_death_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-status")
    {:ok, held} = CapacityGovernor.admit(operation, %{}, name)
    parent = self()

    owner =
      Task.async(fn ->
        send(
          parent,
          {:deferred_owner, CapacityGovernor.try_admit(operation, %{purpose: :recovery}, name)}
        )

        receive do: (:stop -> :ok)
      end)

    assert_receive {:deferred_owner, {:defer, _}}
    assert {:defer, _} = CapacityGovernor.try_admit(operation, %{}, name)
    CapacityGovernor.complete(held, 200, name)
    assert {:defer, _} = CapacityGovernor.try_admit(operation, %{}, name)
    Task.shutdown(owner, :brutal_kill)
    await_queue(name)
    assert {:ok, admission} = CapacityGovernor.try_admit(operation, %{}, name)
    assert {:defer, _} = CapacityGovernor.try_admit(operation, %{request_key: :stale}, name)
    stop_supervised!(CapacityGovernor)
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    CapacityGovernor.complete(admission, 200, name)

    assert %{deferred: %{}, in_flight: 0, admitted_capacity: 1} =
             CapacityGovernor.diagnostics(name)

    assert {:ok, _} = CapacityGovernor.try_admit(operation, %{}, name)
  end

  defp await_queue(name, count \\ 1, remaining \\ 1_000)
  defp await_queue(_name, _count, 0), do: flunk("admission never queued")

  defp await_queue(name, count, remaining) do
    queued =
      CapacityGovernor.diagnostics(name).deferred
      |> Map.values()
      |> Enum.map(& &1.count)
      |> Enum.sum()

    if queued == count do
      :ok
    else
      Process.sleep(1)
      await_queue(name, count, remaining - 1)
    end
  end
end
