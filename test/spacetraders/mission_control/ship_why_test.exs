defmodule SpaceTraders.MissionControl.ShipWhyTest do
  @moduledoc "Ship + Why projection (#772): what a Ship chose, what it beat, and whether it paid off."
  use SpaceTraders.DataCase, async: false

  import Ecto.Query

  alias SpaceTraders.Fleet.Intent
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

  describe "a skipped buy (#813)" do
    setup do
      seeded = ScenarioSeeds.seed(:healthy, 2)
      ship = Repo.get_by!(SpaceTraders.Fleet.Ship, symbol: "SEEDED-1")
      template = Repo.one!(from i in Intent, where: i.ship_id == ^ship.id, limit: 1)
      %{seeded: seeded, template: template}
    end

    defp skip(template, finished, observed, max) do
      Repo.insert!(%{
        template
        | id: nil,
          type: "buy",
          status: "infeasible",
          target_waypoint: "X1-UX81-A1",
          parameters: %{"trade_symbol" => "FUEL"},
          last_action_result: %{
            "outcome" => "infeasible",
            "evidence" => %{
              "reason" => "price_constraint",
              "observed_price" => observed,
              "max_price" => max
            }
          },
          finished_at: finished
      })
    end

    test "names the last refused buy: good, Waypoint, live price, planned maximum, time",
         %{seeded: seeded, template: template} do
      newer = DateTime.truncate(DateTime.add(seeded.now, -120), :second)
      skip(template, DateTime.truncate(DateTime.add(seeded.now, -600), :second), 50, 40)
      skip(template, newer, 66, 63)

      assert %{
               good: "FUEL",
               waypoint: "X1-UX81-A1",
               observed_price: 66,
               max_price: 63,
               at: ^newer,
               bought_since?: false
             } = why(seeded, "SEEDED-1").last_skipped_buy
    end

    test "separates a successful replan (a later buy completed) from a skip with none",
         %{seeded: seeded, template: template} do
      skip(template, DateTime.truncate(DateTime.add(seeded.now, -120), :second), 66, 63)

      Repo.insert!(%{
        template
        | id: nil,
          type: "buy",
          status: "completed",
          target_waypoint: "X1-UX81-A1",
          parameters: %{"trade_symbol" => "FUEL"},
          finished_at: DateTime.truncate(DateTime.add(seeded.now, -118), :second)
      })

      assert %{bought_since?: true} = why(seeded, "SEEDED-1").last_skipped_buy
    end

    test "a later buy of another good or Waypoint is not a replan",
         %{seeded: seeded, template: template} do
      skip(template, DateTime.truncate(DateTime.add(seeded.now, -120), :second), 66, 63)
      later = DateTime.truncate(DateTime.add(seeded.now, -118), :second)

      for {good, waypoint} <- [{"IRON_ORE", "X1-UX81-A1"}, {"FUEL", "X1-UX81-B2"}] do
        Repo.insert!(%{
          template
          | id: nil,
            type: "buy",
            status: "completed",
            target_waypoint: waypoint,
            parameters: %{"trade_symbol" => good},
            finished_at: later
        })
      end

      assert %{bought_since?: false} = why(seeded, "SEEDED-1").last_skipped_buy
    end

    test "a skip older than the status window is not shown",
         %{seeded: seeded, template: template} do
      skip(template, DateTime.truncate(DateTime.add(seeded.now, -31 * 60), :second), 66, 63)

      assert why(seeded, "SEEDED-1").last_skipped_buy == nil
    end

    test "no skipped buy means no entry", %{seeded: seeded} do
      assert why(seeded, "SEEDED-1").last_skipped_buy == nil
    end
  end
end
