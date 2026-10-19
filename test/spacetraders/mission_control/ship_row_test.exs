defmodule SpaceTraders.MissionControl.ShipRowTest do
  @moduledoc """
  When a Ship's stored state is overdue (spec #757 "old"). Seam:
  `MissionControl.ShipRow.build/3` over a stored Ship and its status.
  """
  use ExUnit.Case, async: true

  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.MissionControl.ShipRow

  @now ~U[2026-10-19 12:00:00Z]

  defp at(seconds), do: DateTime.add(@now, seconds)

  defp ship(attrs) do
    struct!(
      Ship,
      Map.merge(
        %{
          id: 1,
          symbol: "AGENT-1",
          nav_status: "DOCKED",
          waypoint_symbol: "X1-A-A1",
          state_observed_at: at(-3600),
          cargo: []
        },
        attrs
      )
    )
  end

  defp status(attrs \\ %{}),
    do: Map.merge(%{acting?: false, next_attempt_at: nil, next_check_at: nil}, attrs)

  test "a parked Ship with no next expected event is never overdue" do
    row = ShipRow.build(ship(%{}), status(), @now)

    refute row.overdue?
    assert row.overdue_at == nil
  end

  test "a Ship with an action running is overdue 5 min after its last observation" do
    row = ShipRow.build(ship(%{state_observed_at: at(-301)}), status(%{acting?: true}), @now)

    assert row.overdue?
    assert row.overdue_at == at(-1)
  end

  test "a Ship cooling down is expected at its cooldown end, not its observation" do
    cooling = ship(%{state_observed_at: at(-600), cooldown_expires_at: at(120)})
    row = ShipRow.build(cooling, status(%{acting?: true}), @now)

    refute row.overdue?
    assert row.overdue_at == at(420)
  end

  test "a cooldown that ended before the observation sets no expectation" do
    idle = ship(%{state_observed_at: at(-600), cooldown_expires_at: at(-900)})

    assert ShipRow.build(idle, status(), @now).overdue_at == nil
  end

  test "a Ship in transit is expected at arrival" do
    flying =
      ship(%{
        nav_status: "IN_TRANSIT",
        route_departed_at: at(-900),
        route_arrives_at: at(-301),
        state_observed_at: at(-900)
      })

    assert ShipRow.build(flying, status(), @now).overdue?
  end

  test "a stuck Ship is expected at its next attempt; a waiting one at its next check" do
    stuck = ShipRow.build(ship(%{}), status(%{next_attempt_at: at(60)}), @now)
    waiting = ShipRow.build(ship(%{}), status(%{next_check_at: at(-400)}), @now)

    assert stuck.overdue_at == at(360)
    refute stuck.overdue?
    assert waiting.overdue?
  end
end
