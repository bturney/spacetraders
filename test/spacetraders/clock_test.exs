defmodule SpaceTraders.ClockTest do
  # The selected clock lives in application-wide configuration.
  use ExUnit.Case, async: false

  alias SpaceTraders.Clock
  alias SpaceTraders.TestClock

  setup do
    previous_clock = Application.fetch_env(:spacetraders, :clock)

    on_exit(fn ->
      case previous_clock do
        {:ok, clock} -> Application.put_env(:spacetraders, :clock, clock)
        :error -> Application.delete_env(:spacetraders, :clock)
      end
    end)
  end

  for clock <- [:live, :controlled] do
    @clock clock
    test "#{clock} clock cancels a scheduled wake without cancelling another" do
      install_clock(@clock)
      due_at = DateTime.add(Clock.utc_now(), 200, :millisecond)
      cancelled = Clock.send_at(self(), :cancelled, due_at)
      Clock.send_at(self(), :kept, due_at)

      assert is_integer(Clock.cancel_timer(cancelled))
      assert Clock.cancel_timer(cancelled) == false
      assert Clock.cancel_timer(make_ref()) == false

      if @clock == :controlled, do: TestClock.advance(200, :millisecond)

      assert_receive :kept, 1_000
      refute_receive :cancelled
    end

    test "#{clock} clock delivers same-time wakes in registration order" do
      install_clock(@clock)
      due_at = DateTime.add(Clock.utc_now(), 200, :millisecond)
      Clock.send_at(self(), {:ordered, :first}, due_at)
      Clock.send_at(self(), {:ordered, :second}, due_at)
      Clock.send_at(self(), {:ordered, :third}, due_at)

      if @clock == :controlled, do: TestClock.advance(200, :millisecond)

      assert_receive {:ordered, first}, 1_000
      assert first == :first
      assert_receive {:ordered, :second}
      assert_receive {:ordered, :third}
      refute_receive {:ordered, _}
    end

    test "#{clock} clock cannot retract an already-due wake" do
      install_clock(@clock)
      reference = Clock.send_at(self(), :already_due, DateTime.add(Clock.utc_now(), -1, :second))
      assert_receive :already_due, 1_000
      assert Clock.cancel_timer(reference) == false
      refute_receive :already_due
    end

    test "#{clock} clock tolerates a dead destination without losing another wake" do
      install_clock(@clock)
      {destination, monitor} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^monitor, :process, ^destination, :normal}
      Clock.send_after(destination, :discarded, 100)
      Clock.send_after(self(), :surviving, 200)

      if @clock == :controlled do
        assert TestClock.next_due_at() == ~U[2030-01-01 00:00:00.200Z]
        TestClock.advance(200, :millisecond)
      end

      assert_receive :surviving, 1_000
      refute_receive :discarded
      if @clock == :controlled, do: assert(TestClock.next_due_at() == nil)
    end
  end

  test "controlled wakes respect chronological order across a multi-deadline advance" do
    install_clock(:controlled)
    Clock.send_after(self(), {:chronological, :early}, 100)
    Clock.send_after(self(), {:chronological, :late}, 300)
    Clock.send_after(self(), {:chronological, :middle}, 200)
    TestClock.advance(300, :millisecond)

    assert_receive {:chronological, first}
    assert first == :early
    assert_receive {:chronological, second}
    assert second == :middle
    assert_receive {:chronological, :late}
  end

  test "infrastructure wall-time waits still run while semantic time is frozen" do
    install_clock(:controlled)
    Clock.send_after(self(), :semantic, 10)
    Process.send_after(self(), :liveness, 10)

    assert_receive :liveness, 1_000
    assert Clock.utc_now() == ~U[2030-01-01 00:00:00Z]
    refute_receive :semantic

    TestClock.advance(10, :millisecond)
    assert_receive :semantic
  end

  defp install_clock(:live), do: Application.delete_env(:spacetraders, :clock)

  defp install_clock(:controlled) do
    start_supervised!({TestClock, ~U[2030-01-01 00:00:00Z]})
    Application.put_env(:spacetraders, :clock, TestClock)
  end

  test "uses an installed controllable clock across processes" do
    now = ~U[2026-09-14 12:00:00Z]
    start_supervised!({TestClock, now})

    Application.put_env(:spacetraders, :clock, TestClock)

    assert Task.async(&Clock.utc_now/0) |> Task.await() == now

    Clock.send_at(self(), :wake_up, DateTime.add(now, 5, :minute))
    refute_receive :wake_up

    assert TestClock.advance(5, :minute) == ~U[2026-09-14 12:05:00Z]
    assert_receive :wake_up
    assert Task.async(&Clock.utc_now/0) |> Task.await() == ~U[2026-09-14 12:05:00Z]
  end
end
