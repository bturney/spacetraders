defmodule SpaceTraders.MissionControl.ShipWhyTest do
  @moduledoc "Ship + Why projection (#772): what a Ship chose, what it beat, and whether it paid off."
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.MissionControl.ShipWhy
  alias SpaceTraders.ScenarioSeeds

  defp why(seeded, symbol) do
    {:ok, why} = ShipWhy.for_ship(seeded.agent, symbol, seeded.now)
    why
  end

  test "an unknown Ship has no page" do
    seeded = ScenarioSeeds.seed(:healthy, 2)
    assert {:error, :not_found} = ShipWhy.for_ship(seeded.agent, "NOPE-1", seeded.now)
  end

  describe "a trading Ship" do
    setup do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      %{seeded: seeded, why: why(seeded, "SEEDED-1")}
    end

    test "names the trade it chose, its estimate after fuel, duration, rate and price age", %{
      why: why
    } do
      assert why.status.kind == :trading

      assert %{
               good: "IRON_ORE",
               source: "X1-UX81-A1",
               destination: "X1-UX81-B6",
               net_credits: 540,
               seconds: 1_320,
               rate: 1_473,
               price_age_seconds: 600
             } = why.choice
    end

    test "lists the alternatives it beat, best first, and charts the choice among them", %{
      why: why
    } do
      assert [%{rate: 1_315, good: "FUEL"}, %{rate: 1_036}] = why.choice.alternatives

      assert [%{chosen?: true, rate: 1_473}, %{chosen?: false, rate: 1_315}, %{rate: 1_036}] =
               why.options
    end

    test "compares expected with actual for its last 10 trades, oldest first", %{why: why} do
      assert length(why.history) == 10
      finished = Enum.map(why.history, & &1.finished_at)
      assert finished == Enum.sort(finished, DateTime)

      assert %{expected: 1_000, actual: actual, good: "IRON_ORE"} = hd(why.history)
      assert is_integer(actual)
    end

    test "carries the credits per Ship-hour gauge", %{why: why} do
      assert is_integer(why.credits_per_hour) and why.credits_per_hour > 0
    end
  end

  test "a waiting Ship names the best option and when it checks again" do
    seeded = ScenarioSeeds.seed(:waiting, 2)
    why = why(seeded, "SEEDED-1")

    assert why.status.kind == :waiting
    assert why.choice == nil

    assert %{good: "COPPER_ORE", net_credits: 55, rate: 150} = why.wait.best
    assert DateTime.compare(why.wait.next_check_at, seeded.now) == :gt
    assert %DateTime{} = why.wait.last_checked_at
  end

  test "a stuck Ship gives its reason and retry state" do
    seeded = ScenarioSeeds.seed(:stuck, 2)
    why = why(seeded, "SEEDED-1")

    assert why.status.kind == :stuck
    assert why.status.reason == "Not enough credits above the floor."
    assert why.status.retries == 2
    assert %DateTime{} = why.status.next_attempt_at
  end
end
