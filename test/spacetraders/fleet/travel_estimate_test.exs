defmodule SpaceTraders.Fleet.TravelEstimateTest do
  use ExUnit.Case, async: true

  import SpaceTraders.ShipBody

  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet.TravelEstimate

  defp ship(opts \\ []) do
    status = Keyword.get(opts, :status, "IN_ORBIT")
    speed = Keyword.get(opts, :speed, 10)
    fuel = Keyword.get(opts, :fuel, 100)

    "S-1"
    |> ship_body(%{
      "nav" => nav_body(status),
      "fuel" => %{"capacity" => 200, "current" => fuel},
      "engine" => %{
        "symbol" => "ENGINE_IMPULSE_DRIVE_I",
        "name" => "Impulse",
        "description" => "e",
        "condition" => 100,
        "integrity" => 100,
        "speed" => speed,
        "requirements" => %{"power" => 1, "crew" => 1}
      },
      "modules" => Keyword.get(opts, :modules, [])
    })
    |> Model.Ship.from_json()
  end

  # The fixture Ship sits at (1, 2); (31, 42) is exactly 50 away.
  defp target(overrides \\ %{}) do
    Map.merge(
      %{symbol: "X1-UX81-B2", system_symbol: "X1-UX81", x: 31, y: 42, freshness: :fresh},
      overrides
    )
  end

  describe "fuel/2" do
    test "CRUISE and STEALTH use max(1, round(distance))" do
      for mode <- ["CRUISE", "STEALTH"] do
        assert TravelEstimate.fuel(0.0, mode) == 1
        assert TravelEstimate.fuel(0.4, mode) == 1
        assert TravelEstimate.fuel(2.4, mode) == 2
        assert TravelEstimate.fuel(2.6, mode) == 3
        assert TravelEstimate.fuel(50.0, mode) == 50
      end
    end

    test "DRIFT is always 1" do
      assert TravelEstimate.fuel(0.0, "DRIFT") == 1
      assert TravelEstimate.fuel(500.0, "DRIFT") == 1
    end

    test "BURN is max(2, 2 * round(distance))" do
      assert TravelEstimate.fuel(0.0, "BURN") == 2
      assert TravelEstimate.fuel(0.4, "BURN") == 2
      assert TravelEstimate.fuel(1.0, "BURN") == 2
      assert TravelEstimate.fuel(2.6, "BURN") == 6
      assert TravelEstimate.fuel(50.0, "BURN") == 100
    end
  end

  describe "seconds/4" do
    test "applies rounded distance, multiplier over engine speed, and the 15 second addition" do
      assert TravelEstimate.seconds(50.0, "CRUISE", "navigate", 10) == 140
      assert TravelEstimate.seconds(50.0, "CRUISE", "navigate", 30) == 57
      assert TravelEstimate.seconds(50.0, "DRIFT", "navigate", 10) == 1265
      assert TravelEstimate.seconds(50.0, "BURN", "navigate", 10) == 78
      assert TravelEstimate.seconds(50.0, "STEALTH", "navigate", 10) == 165
    end

    test "warp uses the warp multipliers" do
      assert TravelEstimate.seconds(50.0, "CRUISE", "warp", 10) == 265
      assert TravelEstimate.seconds(50.0, "DRIFT", "warp", 10) == 1515
    end

    test "zero distance is treated as 1 and rounding applies before the multiplier" do
      assert TravelEstimate.seconds(0.0, "CRUISE", "navigate", 10) == 18
      assert TravelEstimate.seconds(2.4, "CRUISE", "navigate", 10) == 20
      assert TravelEstimate.seconds(2.6, "CRUISE", "navigate", 10) == 23
    end
  end

  describe "estimate/5" do
    test "reports fuel, remaining fuel, fit, distance, and duration from live Ship state" do
      est = TravelEstimate.estimate(ship(), target(), "navigate", "CRUISE")

      assert %{
               status: :ok,
               method: "navigate",
               flight_mode: "CRUISE",
               destination: "X1-UX81-B2",
               current_fuel: 100,
               fuel_cost: 50,
               remaining_fuel: 50,
               fits_tank?: true,
               seconds: 140
             } = est

      assert_in_delta est.distance, 50.0, 0.001
      assert est.warnings == []
    end

    test "insufficient fuel is a corrective blocker" do
      est = TravelEstimate.estimate(ship(fuel: 10), target(), "navigate", "CRUISE")

      assert est.status == :insufficient_fuel
      assert est.fits_tank? == false
      assert est.remaining_fuel == -40
      assert Enum.any?(est.warnings, &(&1 =~ "refuel"))
    end

    test "a cheaper Flight Mode can make the same leg fit" do
      assert TravelEstimate.estimate(ship(fuel: 10), target(), "navigate", "DRIFT").status == :ok
    end

    test "missing destination coordinates are uncertain, never a number" do
      est = TravelEstimate.estimate(ship(), target(%{x: nil, y: nil}), "navigate", "CRUISE")

      assert est.status == :uncertain
      assert est.distance == nil and est.fuel_cost == nil and est.seconds == nil
      assert Enum.any?(est.warnings, &(&1 =~ "coordinates are missing"))
    end

    test "stale coordinates still estimate but warn" do
      est = TravelEstimate.estimate(ship(), target(%{freshness: :stale}), "navigate", "CRUISE")

      assert est.status == :ok
      assert Enum.any?(est.warnings, &(&1 =~ "stale"))
    end

    test "missing engine speed leaves time unknown without hiding fuel" do
      est = TravelEstimate.estimate(%{ship() | engine: nil}, target(), "navigate", "CRUISE")

      assert est.status == :uncertain
      assert est.seconds == nil
      assert est.fuel_cost == 50
      assert Enum.any?(est.warnings, &(&1 =~ "Engine speed"))
    end

    test "missing current fuel is uncertain about fit" do
      est = TravelEstimate.estimate(%{ship() | fuel: nil}, target(), "navigate", "CRUISE")

      assert est.status == :uncertain
      assert est.fits_tank? == nil
      assert Enum.any?(est.warnings, &(&1 =~ "Current fuel"))
    end

    test "docked and in-transit Ships get a prerequisite warning" do
      docked = TravelEstimate.estimate(ship(status: "DOCKED"), target(), "navigate", "CRUISE")
      assert Enum.any?(docked.warnings, &(&1 =~ "docked"))

      moving = TravelEstimate.estimate(ship(status: "IN_TRANSIT"), target(), "navigate", "CRUISE")
      assert Enum.any?(moving.warnings, &(&1 =~ "in transit"))
    end

    test "a destination in another System cannot be navigated" do
      est =
        TravelEstimate.estimate(ship(), target(%{system_symbol: "X1-ZZ9"}), "navigate", "CRUISE")

      assert est.status == :uncertain
      assert Enum.any?(est.warnings, &(&1 =~ "another System"))
    end

    test "unconfirmed multipliers are flagged" do
      est = TravelEstimate.estimate(ship(), target(), "navigate", "BURN")
      assert Enum.any?(est.warnings, &(&1 =~ "unconfirmed"))
    end

    test "warp without System coordinates is uncertain and says a jump uses another rule" do
      est = TravelEstimate.estimate(ship(), target(%{system_symbol: "X1-ZZ9"}), "warp", "CRUISE")

      assert est.status == :uncertain
      assert Enum.any?(est.warnings, &(&1 =~ "jump does not use this fuel formula"))
      assert Enum.any?(est.warnings, &(&1 =~ "Warp Drive"))
    end

    test "warp with System coordinates and a Warp Drive uses the warp multiplier" do
      s = ship(modules: [%{"symbol" => "MODULE_WARP_DRIVE_I"}])

      est =
        TravelEstimate.estimate(
          s,
          target(%{system_symbol: "X1-ZZ9"}),
          "warp",
          "CRUISE",
          origin_system: %{x: 0, y: 0},
          target_system: %{x: 30, y: 40}
        )

      assert est.fuel_cost == 50
      assert est.seconds == 265
      refute Enum.any?(est.warnings, &(&1 =~ "Warp Drive"))
    end

    test "an unreadable Ship yields an uncertain estimate" do
      assert TravelEstimate.estimate(nil, target(), "navigate", "CRUISE").status == :uncertain
    end
  end
end
