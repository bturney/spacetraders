defmodule SpaceTraders.Fleet.TradeEstimateTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.Fleet.TradeEstimate

  # Real CRUISE flights from the scrubbed Generation 5 snapshot (formula
  # verification, #752): origin, destination, engine speed and condition,
  # frame fuel capacity, then the game's fuel consumed and arrival − departure.
  @flights [
    # Engine condition 1.0: the wiki formula, exact.
    {{4, 53}, {46, -45}, 36, 1.0, 400, 107, 89},
    {{-25, 2}, {149, -39}, 36, 1.0, 400, 179, 139},
    {{149, -39}, {-74, 14}, 36, 1.0, 400, 229, 174},
    {{25, -2}, {25, -2}, 36, 1.0, 400, 1, 16},
    {{180, 65}, {25, -2}, 36, 1.0, 400, 169, 132},
    {{25, -2}, {324, -122}, 36, 1.0, 400, 322, 239},
    # Probes: no fuel tank, no fuel.
    {{-25, 2}, {5, -26}, 9, 1.0, 0, 0, 129},
    {{-322, -124}, {149, -39}, 9, 1.0, 0, 0, 1346},
    {{324, -122}, {-107, -36}, 9, 1.0, 0, 0, 1234},
    # Worn engines are slower.
    {{-25, 2}, {-74, 14}, 36, 0.9969250117722153, 400, 50, 50},
    {{30, 79}, {25, -2}, 36, 0.9900750926784332, 400, 81, 73},
    {{20, 14}, {335, 85}, 36, 0.9523367275192349, 400, 323, 263},
    {{-74, 14}, {149, -39}, 36, 0.9380783592687523, 400, 229, 195},
    {{-74, 14}, {46, -45}, 36, 0.9003292785648551, 400, 134, 126},
    {{112, -29}, {-16, -43}, 36, 0.8977520105295087, 400, 129, 123},
    {{5, -26}, {149, -39}, 36, 0.8925274337639466, 400, 145, 137},
    {{-16, -43}, {149, -39}, 36, 0.8898809122613615, 400, 165, 154},
    {{-57, -62}, {-322, -124}, 9, 0.9953674196584704, 0, 0, 779},
    {{183, 410}, {-57, -62}, 9, 0.9699431637894986, 0, 0, 1590}
  ]

  describe "a CRUISE leg" do
    test "matches the fuel and flight time of recorded flights" do
      for {{ox, oy}, {dx, dy}, speed, condition, capacity, fuel, seconds} <- @flights do
        leg =
          TradeEstimate.leg(%{x: ox, y: oy}, %{x: dx, y: dy}, %{
            speed: speed,
            condition: condition,
            fuel_capacity: capacity
          })

        assert leg == %{fuel: fuel, seconds: seconds},
               "#{inspect({ox, oy})} → #{inspect({dx, dy})} at #{speed}/#{condition}"
      end
    end

    test "is within one second where the empirical condition fit rounds the other way" do
      # Recorded 2157 s; the fit is within ±1 s on 99.9% of flights.
      leg =
        TradeEstimate.leg(%{x: -322, y: -124}, %{x: 183, y: 410}, %{
          speed: 9,
          condition: 0.979263151820819,
          fuel_capacity: 0
        })

      assert_in_delta leg.seconds, 2157, 1
    end
  end

  describe "a trade" do
    @frigate %{speed: 36, condition: 1.0, fuel_capacity: 400}

    test "nets the spread after fuel per Ship-hour over the empty and loaded legs" do
      # Empty leg 106.62 → 107 fuel, 89 s; loaded leg 178.77 → 179 fuel, 139 s.
      # Fuel 286 units at 72 credits per 100 → 206 credits (rounded up).
      assert {:ok, estimate} =
               TradeEstimate.trade(%{
                 ship: Map.put(@frigate, :position, %{x: 4, y: 53}),
                 source: %{x: 46, y: -45},
                 destination: %{x: 220, y: -86},
                 units: 40,
                 spread: 20,
                 fuel_price: 72
               })

      assert estimate.fuel_units == 286
      assert estimate.fuel_credits == 206
      assert estimate.net_credits == 594
      assert estimate.seconds == 228
      assert estimate.net_credits_per_ship_hour == 9_379
    end

    test "a Ship already at the source flies only the loaded leg" do
      assert {:ok, estimate} =
               TradeEstimate.trade(%{
                 ship: Map.put(@frigate, :position, :source),
                 source: %{x: 4, y: 53},
                 destination: %{x: 46, y: -45},
                 units: 10,
                 spread: 30,
                 fuel_price: 100
               })

      assert estimate.seconds == 89
      assert estimate.fuel_units == 107
      assert estimate.net_credits == 300 - 107
    end

    test "a Ship with no fuel tank needs no fuel price" do
      probe = %{speed: 9, condition: 1.0, fuel_capacity: 0, position: %{x: -25, y: 2}}

      assert {:ok, %{fuel_credits: 0, net_credits: 100}} =
               TradeEstimate.trade(%{
                 ship: probe,
                 source: %{x: 5, y: -26},
                 destination: %{x: 5, y: -26},
                 units: 10,
                 spread: 10,
                 fuel_price: nil
               })
    end

    test "is unknown without engine, coordinates or a needed fuel price" do
      base = %{
        ship: Map.put(@frigate, :position, %{x: 0, y: 0}),
        source: %{x: 1, y: 0},
        destination: %{x: 2, y: 0},
        units: 1,
        spread: 1,
        fuel_price: 10
      }

      assert {:error, :unknown_fuel_price} = TradeEstimate.trade(%{base | fuel_price: nil})

      assert {:error, :unknown_engine} =
               TradeEstimate.trade(%{base | ship: %{base.ship | speed: nil}})

      assert {:error, :unknown_coordinates} = TradeEstimate.trade(%{base | source: nil})
    end
  end
end
