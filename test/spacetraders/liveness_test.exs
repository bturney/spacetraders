defmodule SpaceTraders.LivenessTest do
  @moduledoc "Seam: `SpaceTraders.Liveness` game facts (Plan Health's game-overdue clock)."
  # The clock and the liveness counters are application-wide.
  use ExUnit.Case, async: false

  alias SpaceTraders.{Liveness, TestClock}

  @t0 ~U[2026-10-19 12:00:00.000Z]

  setup do
    start_supervised!({TestClock, @t0})
    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous_clock,
        do: Application.put_env(:spacetraders, :clock, previous_clock),
        else: Application.delete_env(:spacetraders, :clock)

      Liveness.reset()
    end)

    Liveness.reset()
    :ok
  end

  test "a failing game is overdue from its last answer, not its first failure" do
    Liveness.game_request(200)
    TestClock.advance(10, :minute)

    Liveness.game_request(503)
    assert Liveness.game_failing_since() == @t0

    TestClock.advance(1, :minute)
    Liveness.game_request(:transport)
    assert Liveness.game_failing_since() == @t0
  end

  test "an answer clears the failing state" do
    Liveness.game_request(503)
    TestClock.advance(1, :minute)
    Liveness.game_request(404)

    assert Liveness.game_failing_since() == nil
  end

  test "with no answer since boot, failing counts from boot" do
    TestClock.advance(2, :minute)
    Liveness.game_request(503)

    assert Liveness.game_failing_since() == @t0
  end
end
