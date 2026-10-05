defmodule SpaceTraders.Fleet.TravelEstimate do
  @moduledoc """
  Pre-flight fuel and travel-time estimate for a Navigate or Warp leg.

  The formulas are community-compiled observations
  (https://github.com/SpaceTradersAPI/api-docs/wiki/Travel-Fuel-and-Time), not
  guaranteed game rules. An estimate never dispatches anything: the Ship and
  destination are re-read before the real mutation and the game response is
  final. Missing, stale, or unconfirmed inputs surface as warnings or an
  `:uncertain` status instead of a confident number.
  """

  alias SpaceTraders.API.Model

  @flight_modes ~w(DRIFT STEALTH CRUISE BURN)
  @methods ~w(navigate warp)

  # {navigate, warp, unconfirmed?}; the wiki has not confirmed `true` rows on 2.1+.
  @multipliers %{
    "CRUISE" => {25, 50, false},
    "DRIFT" => {250, 300, true},
    "BURN" => {12.5, 25, true},
    "STEALTH" => {30, 60, true}
  }

  def flight_modes, do: @flight_modes
  def methods, do: @methods

  @doc "Euclidean distance between two `{x, y}` points."
  def distance({x1, y1}, {x2, y2}), do: :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2))

  @doc "Fuel for a leg of `distance` in `flight_mode`."
  def fuel(distance, mode) when mode in ["CRUISE", "STEALTH"], do: max(1, round(distance))
  def fuel(_distance, "DRIFT"), do: 1
  def fuel(distance, "BURN"), do: max(2, 2 * round(distance))

  @doc "Travel seconds for a leg: `round(round(max(1, d)) * (multiplier / speed) + 15)`."
  def seconds(distance, mode, method, engine_speed)
      when mode in @flight_modes and method in @methods and is_number(engine_speed) and
             engine_speed > 0 do
    round(round(max(1, distance)) * (multiplier(mode, method) / engine_speed) + 15)
  end

  defp multiplier(mode, method) do
    {navigate, warp, _} = Map.fetch!(@multipliers, mode)
    if method == "warp", do: warp, else: navigate
  end

  @doc """
  Estimates one leg for a live `%Model.Ship{}`.

  `target` is `%{symbol:, system_symbol:, x:, y:, freshness:}`; `freshness` is
  `:fresh`, `:stale`, or `:not_established`. For a warp, `opts[:origin_system]`
  and `opts[:target_system]` must be `%{x:, y:}` System coordinates, otherwise
  the estimate is `:uncertain`.

  Returns a map with `:status` (`:ok`, `:insufficient_fuel`, `:uncertain`), the
  inputs echoed back, the figures when computable, and `:warnings`.
  """
  def estimate(ship, target, method, flight_mode, opts \\ [])

  def estimate(%Model.Ship{} = ship, target, method, flight_mode, opts)
      when method in @methods and flight_mode in @flight_modes do
    origin = origin(ship)
    speed = engine_speed(ship)
    current = fuel_current(ship)
    {distance, leg_warnings} = leg(method, origin, target, opts)

    warnings =
      leg_warnings ++
        speed_warnings(speed) ++
        fuel_warnings(current) ++
        prerequisite_warnings(ship, method) ++
        confirmation_warnings(method, flight_mode) ++
        freshness_warnings(target)

    base = %{
      method: method,
      flight_mode: flight_mode,
      destination: target[:symbol],
      current_fuel: current,
      distance: distance,
      fuel_cost: nil,
      remaining_fuel: nil,
      fits_tank?: nil,
      seconds: nil
    }

    if is_nil(distance) do
      Map.merge(base, %{status: :uncertain, warnings: warnings})
    else
      cost = fuel(distance, flight_mode)
      remaining = current && current - cost
      fits? = remaining && remaining >= 0

      warnings =
        if fits? == false, do: warnings ++ [fuel_blocker(cost, current)], else: warnings

      Map.merge(base, %{
        status: status(fits?, speed),
        warnings: warnings,
        fuel_cost: cost,
        remaining_fuel: remaining,
        fits_tank?: fits?,
        seconds: speed && seconds(distance, flight_mode, method, speed)
      })
    end
  end

  def estimate(_ship, target, method, flight_mode, _opts) do
    %{
      status: :uncertain,
      method: method,
      flight_mode: flight_mode,
      destination: target[:symbol],
      current_fuel: nil,
      distance: nil,
      fuel_cost: nil,
      remaining_fuel: nil,
      fits_tank?: nil,
      seconds: nil,
      warnings: ["Ship state or selection is unavailable; estimate cannot be computed."]
    }
  end

  defp status(false, _speed), do: :insufficient_fuel
  defp status(nil, _speed), do: :uncertain
  defp status(true, nil), do: :uncertain
  defp status(true, _speed), do: :ok

  defp fuel_blocker(cost, current),
    do:
      "Estimated fuel #{cost} exceeds current fuel #{current}; refuel or choose a cheaper Flight Mode."

  defp leg("navigate", origin, target, _opts) do
    cond do
      is_nil(origin) ->
        {nil, ["Ship origin coordinates are unavailable."]}

      not coords?(target) ->
        {nil, ["Destination coordinates are missing; distance cannot be estimated."]}

      target[:system_symbol] && target[:system_symbol] != origin.system ->
        {nil, ["Destination is in another System; use warp or jump instead of Navigate."]}

      true ->
        {distance({origin.x, origin.y}, {target.x, target.y}), []}
    end
  end

  defp leg("warp", origin, target, opts) do
    with %{x: ox, y: oy} <- opts[:origin_system],
         %{x: tx, y: ty} <- opts[:target_system],
         true <- Enum.all?([ox, oy, tx, ty], &is_number/1) do
      if origin && origin.system == target[:system_symbol] do
        {nil, ["Destination is in the current System; use Navigate instead of warp."]}
      else
        {distance({ox, oy}, {tx, ty}), []}
      end
    else
      _ ->
        {nil,
         [
           "System coordinates are not retained; warp distance cannot be estimated. A jump does not use this fuel formula."
         ]}
    end
  end

  defp coords?(%{x: x, y: y}) when is_number(x) and is_number(y), do: true
  defp coords?(_), do: false

  defp origin(%Model.Ship{nav: %Model.ShipNav{route: %{destination: %{x: x, y: y} = dest}} = nav})
       when is_number(x) and is_number(y),
       do: %{x: x, y: y, system: dest.system_symbol || nav.system_symbol}

  defp origin(_), do: nil

  defp engine_speed(%Model.Ship{engine: %{speed: speed}}) when is_number(speed) and speed > 0,
    do: speed

  defp engine_speed(_), do: nil

  defp fuel_current(%Model.Ship{fuel: %{current: current}}) when is_integer(current), do: current
  defp fuel_current(_), do: nil

  defp speed_warnings(nil), do: ["Engine speed is unavailable; travel time cannot be estimated."]
  defp speed_warnings(_), do: []

  defp fuel_warnings(nil), do: ["Current fuel is unavailable; fit cannot be confirmed."]
  defp fuel_warnings(_), do: []

  defp prerequisite_warnings(%Model.Ship{nav: %{status: "DOCKED"}}, _method),
    do: ["Ship is docked; it must be in orbit before it can fly."]

  defp prerequisite_warnings(%Model.Ship{nav: %{status: "IN_TRANSIT"}}, _method),
    do: ["Ship is in transit; wait for arrival before flying."]

  defp prerequisite_warnings(%Model.Ship{} = ship, "warp") do
    if Enum.any?(ship.modules || [], &warp_module?/1),
      do: [],
      else: ["No Warp Drive module is installed; warp is unavailable."]
  end

  defp prerequisite_warnings(_ship, _method), do: []

  defp warp_module?(%{symbol: symbol}) when is_binary(symbol),
    do: String.contains?(symbol, "WARP_DRIVE")

  defp warp_module?(_), do: false

  defp confirmation_warnings(method, mode) do
    {_, _, unconfirmed?} = Map.fetch!(@multipliers, mode)

    if method == "warp" or unconfirmed?,
      do: ["Time multiplier for #{mode} #{method} is community-observed and unconfirmed."],
      else: []
  end

  defp freshness_warnings(%{freshness: :stale}),
    do: ["Destination coordinates are stale; they will be re-read before dispatch."]

  defp freshness_warnings(%{freshness: :not_established}),
    do: ["Destination coordinates are not established."]

  defp freshness_warnings(_), do: []
end
