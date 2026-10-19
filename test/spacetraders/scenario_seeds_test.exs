defmodule SpaceTraders.ScenarioSeedsTest do
  @moduledoc "The five situations at 2 and 120 Ships show the expected Ships-list statuses (#768)."
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.MissionControl.ShipRow
  alias SpaceTraders.ScenarioSeeds

  @expected %{
    healthy: nil,
    busy_not_earning: :busy_not_earning,
    waiting: :waiting,
    stuck: :stuck,
    old_information: :trading
  }

  for situation <- ScenarioSeeds.situations(), size <- ScenarioSeeds.sizes() do
    test "#{situation} at #{size} Ships" do
      situation = unquote(situation)
      seeded = ScenarioSeeds.seed(situation, unquote(size))
      statuses = ScenarioSeeds.statuses(seeded)

      assert map_size(statuses) == unquote(size)

      for {symbol, status} <- statuses do
        expected = if symbol in seeded.affected, do: @expected[situation]
        assert_status(status, expected, symbol)
      end

      assert seeded.affected == [] or situation != :healthy
      assert_overdue(seeded, situation)
    end
  end

  test "seeding again replaces the previous seed" do
    ScenarioSeeds.seed(:stuck, 2)
    seeded = ScenarioSeeds.seed(:waiting, 2)
    statuses = ScenarioSeeds.statuses(seeded)

    assert map_size(statuses) == 2
    assert Enum.all?(seeded.affected, &(statuses[&1].kind == :waiting))
  end

  test "a 120-Ship Fleet has scouts among its traders" do
    counts =
      :healthy
      |> ScenarioSeeds.seed(120)
      |> ScenarioSeeds.statuses()
      |> Map.values()
      |> Enum.frequencies_by(& &1.kind)

    assert counts == %{trading: 108, scouting: 12}
  end

  test "a seeded Fleet never runs: boot re-arms no Ship of it" do
    on_exit(&SpaceTraders.Quiesced.stop_all_ships/0)
    ScenarioSeeds.seed(:stuck, 2)

    assert SpaceTraders.Fleet.Intents.rearm_owned_intents_on_boot() == []
  end

  test "seeding refuses a database holding a Fleet it does not own" do
    SpaceTraders.AgentFixtures.operator_fixture()

    assert_raise ArgumentError, ~r/not seed-owned/, fn -> ScenarioSeeds.seed(:healthy, 2) end
    assert_raise ArgumentError, ~r/not seed-owned/, &ScenarioSeeds.clear!/0
  end

  defp assert_status(status, nil, symbol),
    do: assert(status.kind in [:trading, :scouting], "#{symbol}: #{inspect(status.kind)}")

  defp assert_status(status, expected, symbol),
    do: assert(status.kind == expected, "#{symbol}: #{inspect(status.kind)}")

  defp assert_overdue(seeded, situation) do
    statuses = ScenarioSeeds.statuses(seeded)

    overdue =
      for ship <- SpaceTraders.Fleet.current_ships(seeded.agent.id),
          ShipRow.build(ship, statuses[ship.symbol], seeded.now).overdue?,
          do: ship.symbol

    expected = if situation == :old_information, do: seeded.affected, else: []
    assert Enum.sort(overdue) == expected
  end
end
