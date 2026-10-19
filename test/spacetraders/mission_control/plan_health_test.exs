defmodule SpaceTraders.MissionControl.PlanHealthTest do
  @moduledoc """
  Plan Health (#769): four states, four checks, one plain reason line, and the
  "old" rules. Seam: `MissionControl.PlanHealth.evaluate/2` over read facts.
  """
  use ExUnit.Case, async: true

  alias SpaceTraders.MissionControl.PlanHealth

  @now ~U[2026-10-18 12:00:00Z]

  defp at(seconds), do: DateTime.add(@now, seconds)

  defp ships(statuses) do
    statuses
    |> Enum.with_index(1)
    |> Enum.map(fn {status, n} ->
      %{symbol: "SHIP-#{n}", status: status, reason: nil, overdue_at: at(600)}
    end)
  end

  defp facts(overrides \\ %{}) do
    Map.merge(
      %{
        fleet?: true,
        engine: %{expected?: true, last_beat_at: at(-1)},
        game_failing_since: nil,
        ships: ships(List.duplicate(:trading, 10)),
        neutral_wait: nil,
        shortfall: nil,
        stall: nil,
        earnings: %{last_hour: 2_000, window_net: 12_000, window_hours: 6.0},
        recent_trades: %{count: 20, net: 20_000, expected: 20_000},
        open_trades: [],
        markets: []
      },
      Map.new(overrides)
    )
  end

  defp check(health, name), do: Enum.find(health.checks, &(&1.name == name))

  describe "on plan" do
    test "all four checks pass" do
      health = PlanHealth.evaluate(facts(), @now)

      assert health.state == :on
      assert health.reason == "All four checks pass."

      assert Enum.map(health.checks, & &1.label) ==
               ["Earning", "Ships moving", "Prices fresh", "Trades as expected"]

      assert Enum.all?(health.checks, &(&1.state == :ok))
    end

    test "a deliberate Neutral Wait is on plan even with no earning in the last hour" do
      health =
        PlanHealth.evaluate(
          facts(
            ships: ships(List.duplicate(:waiting, 10)),
            neutral_wait: %{next_check_at: at(600)},
            earnings: %{last_hour: 0, window_net: 12_000, window_hours: 6.0}
          ),
          @now
        )

      assert health.state == :on
      assert health.reason == "Waiting on purpose for a trade worth making; next check 12:10."
      assert check(health, :earning).state == :ok
    end
  end

  describe "small setback" do
    test "a loss over 5,000 in the last hour" do
      health =
        PlanHealth.evaluate(
          facts(earnings: %{last_hour: -5_001, window_net: 6_000, window_hours: 6.0}),
          @now
        )

      assert health.state == :setback
      assert health.reason == "Lost 5,001 in the last hour."
      assert check(health, :earning).state == :amber
    end

    test "a loss of exactly 5,000 is not over the limit" do
      health =
        PlanHealth.evaluate(
          facts(earnings: %{last_hour: -5_000, window_net: -30_000, window_hours: 6.0}),
          @now
        )

      refute check(health, :earning).state == :amber and health.reason =~ "Lost"
    end

    test "earning below 40% of the 6 h average" do
      health =
        PlanHealth.evaluate(
          facts(earnings: %{last_hour: 700, window_net: 12_000, window_hours: 6.0}),
          @now
        )

      assert health.state == :setback
      assert health.reason == "Earned 700 in the last hour against 2,000/h over 6 h."
      assert check(health, :earning).state == :amber
    end

    test "the earning rate is not judged before an hour of history" do
      health =
        PlanHealth.evaluate(
          facts(earnings: %{last_hour: 0, window_net: 0, window_hours: nil}),
          @now
        )

      assert health.state == :on
    end

    test "more than 20% of traders Busy, not earning" do
      health =
        PlanHealth.evaluate(
          facts(ships: ships([:busy_not_earning | List.duplicate(:trading, 3)] ++ [:scouting])),
          @now
        )

      assert health.state == :setback
      assert health.reason == "1 of 4 traders are busy, not earning."
      assert check(health, :ships_moving).state == :amber
    end

    test "exactly 20% of traders Busy, not earning is on plan" do
      health =
        PlanHealth.evaluate(
          facts(ships: ships([:busy_not_earning | List.duplicate(:trading, 4)])),
          @now
        )

      assert health.state == :on
    end

    test "a market behind a live trade past the 30 min freshness limit" do
      health =
        PlanHealth.evaluate(
          facts(markets: [%{waypoint: "X1-UX81-F50", observed_at: at(-44 * 60)}]),
          @now
        )

      assert health.state == :setback
      assert health.reason == "Prices at F50 are 44 min old (trusted up to 30)."
      assert check(health, :prices_fresh).state == :amber
    end

    test "trades realizing under 80% of expected over the last 20" do
      health =
        PlanHealth.evaluate(
          facts(recent_trades: %{count: 20, net: 15_000, expected: 20_000}),
          @now
        )

      assert health.state == :setback
      assert health.reason == "The last 20 trades made 75% of what was expected."
      assert check(health, :trades_as_expected).state == :amber
    end
  end

  describe "off plan" do
    test "spending paused by a Shortfall" do
      health =
        PlanHealth.evaluate(facts(shortfall: %{floor: 1_000, detected_at: at(-600)}), @now)

      assert health.state == :off
      assert health.reason == "Spending paused: credits fell below the 1,000 floor at 11:50."
      assert check(health, :earning).state == :red
    end

    test "allocation stalled (Degraded Operation)" do
      health =
        PlanHealth.evaluate(
          facts(
            stall: %{
              reason: "Allocation stalled: a step lost its authority to act",
              since: at(-120)
            }
          ),
          @now
        )

      assert health.state == :off
      assert health.reason == "Allocation stalled: a step lost its authority to act, since 11:58."
      assert check(health, :ships_moving).state == :red
    end

    test "more than 10% of traders Stuck" do
      statuses = [:stuck, :stuck | List.duplicate(:trading, 8)] ++ [:scouting]
      health = PlanHealth.evaluate(facts(ships: ships(statuses)), @now)

      assert health.state == :off
      assert health.reason == "2 of 10 traders are stuck."
    end

    test "10% of traders Stuck is not off plan" do
      statuses = [:stuck | List.duplicate(:trading, 9)]
      assert PlanHealth.evaluate(facts(ships: ships(statuses)), @now).state == :on
    end

    test "any Ship Stuck with 2 or fewer Ships" do
      [stuck, other] = ships([:stuck, :trading])
      stuck = %{stuck | reason: "Not enough credits above the floor."}
      health = PlanHealth.evaluate(facts(ships: [stuck, other]), @now)

      assert health.state == :off
      assert health.reason == "SHIP-1 is stuck: Not enough credits above the floor."
    end

    test "off plan outranks a small setback" do
      health =
        PlanHealth.evaluate(
          facts(
            shortfall: %{floor: 1_000, detected_at: at(-600)},
            recent_trades: %{count: 20, net: 1_000, expected: 20_000}
          ),
          @now
        )

      assert health.state == :off
      assert check(health, :trades_as_expected).state == :amber
    end
  end

  describe "can't tell right now" do
    test "the engine silent for 60 s says why and since when" do
      health =
        PlanHealth.evaluate(facts(engine: %{expected?: true, last_beat_at: at(-60)}), @now)

      assert health.state == :unknown
      assert health.reason == "The engine has been silent since 11:59."
      assert health.since == at(-60)
    end

    test "the engine heartbeat inside 60 s is not overdue" do
      health =
        PlanHealth.evaluate(facts(engine: %{expected?: true, last_beat_at: at(-59)}), @now)

      assert health.state == :on
      assert health.next_change_at == at(1)
    end

    test "no heartbeat is expected where this runtime runs no engine" do
      health =
        PlanHealth.evaluate(facts(engine: %{expected?: false, last_beat_at: at(-3600)}), @now)

      assert health.state == :on
    end

    test "the game failing for 5 min" do
      health = PlanHealth.evaluate(facts(game_failing_since: at(-300)), @now)

      assert health.state == :unknown
      assert health.reason == "The game has not answered since 11:55."
      assert health.since == at(-300)
    end

    test "game failures under 5 min are not yet overdue" do
      health = PlanHealth.evaluate(facts(game_failing_since: at(-299)), @now)
      assert health.state == :on
      assert health.next_change_at == at(1)
    end

    test "more than half of Ships overdue" do
      [a, b, c] = ships([:trading, :trading, :trading])

      health =
        PlanHealth.evaluate(
          facts(ships: [%{a | overdue_at: at(-120)}, %{b | overdue_at: at(-60)}, c]),
          @now
        )

      assert health.state == :unknown
      assert health.reason == "2 of 3 Ships have not reported since 11:59."
      assert health.since == at(-60)
    end

    test "half of Ships overdue is not can't tell" do
      [a, b] = ships([:trading, :trading])
      health = PlanHealth.evaluate(facts(ships: [%{a | overdue_at: at(-60)}, b]), @now)

      assert health.state == :on
      assert check(health, :ships_moving).detail == "1 Ship has not reported since 11:59."
    end

    test "can't tell outranks off plan" do
      health =
        PlanHealth.evaluate(
          facts(
            game_failing_since: at(-600),
            shortfall: %{floor: 1_000, detected_at: at(-600)}
          ),
          @now
        )

      assert health.state == :unknown
    end

    test "a trade 50% past its estimate with no sale makes earnings too old to judge" do
      health =
        PlanHealth.evaluate(
          facts(open_trades: [%{ship_symbol: "SHIP-1", due_at: at(-300)}]),
          @now
        )

      assert health.state == :unknown
      assert health.reason == "1 trade is well past its estimate; no sale recorded since 11:55."
      assert check(health, :earning).state == :unknown
    end

    test "a trade inside 150% of its estimate is expected later" do
      health =
        PlanHealth.evaluate(
          facts(
            engine: %{expected?: false, last_beat_at: at(-1)},
            open_trades: [%{ship_symbol: "SHIP-1", due_at: at(90)}]
          ),
          @now
        )

      assert health.state == :on
      assert health.next_change_at == at(90)
    end

    test "with no trades running nothing is expected of earnings" do
      health = PlanHealth.evaluate(facts(open_trades: []), @now)
      assert check(health, :earning).state == :ok
    end

    test "a real setback outranks earnings too old to judge" do
      health =
        PlanHealth.evaluate(
          facts(
            open_trades: [%{ship_symbol: "SHIP-1", due_at: at(-300)}],
            recent_trades: %{count: 20, net: 1_000, expected: 20_000}
          ),
          @now
        )

      assert health.state == :setback
    end

    test "no current Fleet" do
      health = PlanHealth.evaluate(%{fleet?: false}, @now)

      assert health.state == :unknown
      assert health.reason == "No current Fleet yet."
      assert Enum.all?(health.checks, &(&1.state == :unknown))
    end

    test "a Fleet with no Ships" do
      health = PlanHealth.evaluate(facts(ships: []), @now)

      assert health.state == :unknown
      assert health.reason == "No Ships reported yet."
    end
  end

  test "the next change is the earliest moment an old rule would flip" do
    [a, b] = ships([:trading, :trading])

    health =
      PlanHealth.evaluate(
        facts(
          engine: %{expected?: true, last_beat_at: at(-1)},
          ships: [%{a | overdue_at: at(30)}, b],
          markets: [%{waypoint: "X1-A1", observed_at: at(-1_790)}]
        ),
        @now
      )

    assert health.next_change_at == at(10)
  end

  test "no copy asks the Operator to act" do
    healths = [
      PlanHealth.evaluate(facts(shortfall: %{floor: 1_000, detected_at: at(-600)}), @now),
      PlanHealth.evaluate(facts(game_failing_since: at(-600)), @now),
      PlanHealth.evaluate(%{fleet?: false}, @now)
    ]

    for health <- healths, text <- [health.reason | Enum.map(health.checks, & &1.detail)] do
      refute text =~ ~r/\b(please|check|review|fix|act|attention|needs you|click)\b/i
    end
  end
end
