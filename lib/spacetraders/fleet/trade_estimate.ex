defmodule SpaceTraders.Fleet.TradeEstimate do
  @moduledoc """
  The one estimate of a trade's net credits per Ship-hour, used by trade
  selection and Ship purchase valuation alike.

  A trade is the empty leg from where the Ship is to the source plus the
  loaded leg to the destination, both flown in CRUISE:

      net credits per Ship-hour = (units × spread − fuel credits) ÷ flight hours

  Per leg, with `d` the Euclidean distance between Waypoint coordinates
  (formula verification, `docs/research/fuel-flight-time-formulas.md`, #752):

  - fuel is `max(1, round(d))`, or 0 for a Ship without a fuel tank;
  - seconds are `round(15 + round(max(1, d)) × 25 ÷ engine speed × m)`, where
    `m = 1 + 2.52x ÷ (1 + 2.78x)` and `x = 1 − engine condition`.

  Engine speed and condition come from the Ship, never a component table.
  Fuel credits price the fuel at the FUEL purchase price, which buys 100 fuel
  per market unit. Non-CRUISE modes, warp and jumps are out of scope (#754).
  Everything here is pure; the game's arrival and fuel consumed stay
  authoritative, and this is for ranking only.
  """

  @model "cruise-flight-v1"
  @fuel_per_market_unit 100
  @cruise_multiplier 25

  @doc "The model version recorded with every estimate."
  def model, do: @model

  @doc """
  Fuel and whole seconds for one CRUISE leg between two `%{x, y}` points by a
  Ship `%{speed, condition, fuel_capacity}`.
  """
  def leg(%{x: x1, y: y1}, %{x: x2, y: y2}, %{
        speed: speed,
        condition: condition,
        fuel_capacity: capacity
      }) do
    distance = :math.sqrt((x1 - x2) ** 2 + (y1 - y2) ** 2)
    rounded = round(max(1, distance))
    worn = 1 - condition
    slowdown = 1 + 2.52 * worn / (1 + 2.78 * worn)

    %{
      fuel: if(capacity == 0, do: 0, else: max(1, round(distance))),
      seconds: round(15 + rounded * @cruise_multiplier / speed * slowdown)
    }
  end

  @doc """
  Estimates one trade for one Ship.

  `ship` is `%{speed, condition, fuel_capacity, position}`, where `position`
  is `%{x, y}` or `:source` when the Ship is already at the source.
  `fuel_price` is the FUEL purchase price per market unit, or nil when none
  is known (only a Ship without a fuel tank can do without it).

  Returns `{:ok, estimate}` or `{:error, :unknown_engine | :unknown_coordinates
  | :unknown_fuel_price}`.
  """
  def trade(%{ship: ship, source: source, destination: destination} = input) do
    with :ok <- engine(ship),
         :ok <- coordinates([source, destination | empty_start(ship.position)]) do
      empty =
        if ship.position == :source,
          do: %{fuel: 0, seconds: 0},
          else: leg(ship.position, source, ship)

      loaded = leg(source, destination, ship)
      fuel_units = empty.fuel + loaded.fuel

      with {:ok, fuel_credits} <- fuel_credits(fuel_units, input.fuel_price) do
        net = input.units * input.spread - fuel_credits
        seconds = empty.seconds + loaded.seconds

        {:ok,
         %{
           model: @model,
           units: input.units,
           spread: input.spread,
           fuel_price: input.fuel_price,
           fuel_units: fuel_units,
           fuel_credits: fuel_credits,
           net_credits: net,
           empty_seconds: empty.seconds,
           loaded_seconds: loaded.seconds,
           seconds: seconds,
           net_credits_per_ship_hour: round(net * 3_600 / seconds)
         }}
      end
    end
  end

  defp engine(%{speed: speed, condition: condition, fuel_capacity: capacity})
       when is_number(speed) and speed > 0 and is_number(condition) and condition >= 0 and
              condition <= 1 and is_integer(capacity) and capacity >= 0,
       do: :ok

  defp engine(_ship), do: {:error, :unknown_engine}

  defp empty_start(:source), do: []
  defp empty_start(position), do: [position]

  defp coordinates(points) do
    if Enum.all?(points, &match?(%{x: x, y: y} when is_integer(x) and is_integer(y), &1)),
      do: :ok,
      else: {:error, :unknown_coordinates}
  end

  defp fuel_credits(0, _price), do: {:ok, 0}

  defp fuel_credits(units, price) when is_integer(price) and price >= 0,
    do: {:ok, ceil(units * price / @fuel_per_market_unit)}

  defp fuel_credits(_units, _price), do: {:error, :unknown_fuel_price}
end
