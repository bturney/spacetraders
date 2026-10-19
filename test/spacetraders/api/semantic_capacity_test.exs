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

  defp await_queue(name, remaining \\ 1_000)
  defp await_queue(_name, 0), do: flunk("admission never queued")

  defp await_queue(name, remaining) do
    case CapacityGovernor.diagnostics(name).deferred do
      %{standard: %{count: 1}} ->
        :ok

      _ ->
        Process.sleep(1)
        await_queue(name, remaining - 1)
    end
  end
end
