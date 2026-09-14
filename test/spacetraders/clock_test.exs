defmodule SpaceTraders.ClockTest do
  use ExUnit.Case, async: false

  alias SpaceTraders.Clock
  alias SpaceTraders.TestClock

  test "uses an installed controllable clock across processes" do
    now = ~U[2026-09-14 12:00:00Z]
    start_supervised!({TestClock, now})

    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous_clock do
        Application.put_env(:spacetraders, :clock, previous_clock)
      else
        Application.delete_env(:spacetraders, :clock)
      end
    end)

    assert Task.async(&Clock.utc_now/0) |> Task.await() == now

    Clock.send_at(self(), :wake_up, DateTime.add(now, 5, :minute))
    refute_receive :wake_up

    assert TestClock.advance(5, :minute) == ~U[2026-09-14 12:05:00Z]
    assert_receive :wake_up
    assert Task.async(&Clock.utc_now/0) |> Task.await() == ~U[2026-09-14 12:05:00Z]
  end
end
