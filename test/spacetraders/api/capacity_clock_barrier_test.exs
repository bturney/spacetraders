defmodule SpaceTraders.API.CapacityClockBarrierTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.API.{CapacityGovernor, OperationInventory, RateLimiter}
  alias SpaceTraders.Simulation.NavigationClock

  setup do
    previous = Application.fetch_env(:spacetraders, :clock)
    start_supervised!({NavigationClock, epoch: ~U[2026-10-19 00:00:00Z]})
    Application.put_env(:spacetraders, :clock, NavigationClock)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:spacetraders, :clock, value)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)

    :ok
  end

  test "read-only governor diagnostics do not invalidate a drained instant" do
    name = :barrier_governor
    start_supervised!({CapacityGovernor, name: name})
    before = NavigationClock.snapshot()
    assert %{in_flight: 0} = CapacityGovernor.diagnostics(name)
    assert %{unresolved: 0} = GenServer.call(name, :simulation_barrier)
    assert NavigationClock.snapshot().revision == before.revision
    assert {:ok, _lease} = NavigationClock.seal(before.revision)
  end

  test "in-flight transport is unresolved, while completed scarcity owns acknowledged release work" do
    name = :release_barrier_governor
    start_supervised!({CapacityGovernor, name: name, max_in_flight: 1})
    operation = OperationInventory.fetch!("get-status")
    {:ok, admission} = CapacityGovernor.try_admit(operation, %{}, name)
    assert %{unresolved: 1} = GenServer.call(name, :simulation_barrier)
    assert {:defer, %{reason: :contention}} = CapacityGovernor.try_admit(operation, %{}, name)
    assert NavigationClock.snapshot().next_wake == nil

    CapacityGovernor.protocol_rejected(2, name)
    CapacityGovernor.complete(admission, 429, name)
    assert %{unresolved: 0} = GenServer.call(name, :simulation_barrier)
    snapshot = NavigationClock.snapshot()
    assert snapshot.next_wake == ~U[2026-10-19 00:00:02.000000Z]
    assert {:ok, lease} = NavigationClock.seal(snapshot.revision)
    assert :ok = NavigationClock.release(lease, snapshot.next_wake, [])
    assert %{unresolved: 0} = GenServer.call(name, :simulation_barrier)
    assert NavigationClock.snapshot().released == %{}
    assert NavigationClock.snapshot().active == %{}
    assert NavigationClock.snapshot().failed == nil
    {:ok, probe} = CapacityGovernor.try_admit(operation, %{}, name)
    CapacityGovernor.complete(probe, 200, name)
    assert %{unresolved: 0} = GenServer.call(name, :simulation_barrier)
  end

  test "protocol releases are registered and acknowledged without gifting tokens" do
    name = :release_barrier_limiter
    start_supervised!({RateLimiter, name: name, burst: 1, pool_burst: 0, rate: 2.0})
    assert :ok = RateLimiter.try_acquire(name)
    assert {:defer, at} = RateLimiter.try_acquire(name)
    assert %{unresolved: 0, release_at: ^at} = GenServer.call(name, :simulation_barrier)
    snapshot = NavigationClock.snapshot()
    assert snapshot.next_wake == ~U[2026-10-19 00:00:00.500000Z]
    assert {:ok, lease} = NavigationClock.seal(snapshot.revision)
    assert :ok = NavigationClock.release(lease, at, [])
    assert %{unresolved: 0, release_at: nil} = GenServer.call(name, :simulation_barrier)
    assert NavigationClock.snapshot().released == %{}
    assert NavigationClock.snapshot().active == %{}
    assert NavigationClock.snapshot().failed == nil
    assert :ok = RateLimiter.try_acquire(name)
    assert {:defer, ~U[2026-10-19 00:00:01.000000Z]} = RateLimiter.try_acquire(name)
  end
end
