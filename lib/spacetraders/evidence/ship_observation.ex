defmodule SpaceTraders.Evidence.ShipObservation do
  @moduledoc "Validates the owned facts used by Ship Execution, including absence and timer proofs."

  alias SpaceTraders.API.Model
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.Observation

  def validate(%Model.Ship{symbol: symbol} = ship, symbol) when is_binary(symbol) do
    if valid_nav?(ship.nav) and valid_fuel?(ship.fuel) and valid_cargo?(ship.cargo) and
         valid_cooldown?(ship.cooldown, symbol) and is_list(ship.modules) and
         Enum.all?(ship.modules, &valid_module?/1) and is_list(ship.mounts) do
      :ok
    else
      {:error, :authoritative_ship_facts_required}
    end
  rescue
    _ -> {:error, :authoritative_ship_facts_required}
  end

  def validate(_, _), do: {:error, :authoritative_ship_facts_required}

  def matches?(%Observation{} = observation, ship, symbol, since) do
    now = SpaceTraders.Clock.utc_now()

    validate(ship, symbol) == :ok and Evidence.valid_observation?(observation) and
      observation.operation_id == "get-my-ship" and
      DateTime.diff(now, observation.observed_at, :millisecond) in 0..30_000 and
      (is_nil(since) or DateTime.compare(observation.observed_at, since) != :lt) and
      observation.facts["response"] == stringify(ship)
  end

  def matches?(_, _, _, _), do: false

  defp valid_nav?(%{
         status: status,
         flight_mode: mode,
         system_symbol: system,
         waypoint_symbol: waypoint,
         route: route
       }) do
    status in ~w(DOCKED IN_ORBIT IN_TRANSIT) and mode in ~w(DRIFT STEALTH CRUISE BURN) and
      nonempty?(system) and nonempty?(waypoint) and
      match?(
        %{origin: %{symbol: origin}, destination: %{symbol: destination}}
        when is_binary(origin) and is_binary(destination),
        route
      ) and
      valid_time?(route.departure_time) and valid_time?(route.arrival)
  end

  defp valid_nav?(_), do: false

  defp valid_fuel?(%{current: current, capacity: capacity}),
    do: is_integer(current) and is_integer(capacity) and current >= 0 and capacity >= current

  defp valid_fuel?(_), do: false

  defp valid_cargo?(%{units: units, capacity: capacity, inventory: inventory})
       when is_integer(units) and is_integer(capacity) and is_list(inventory) do
    units >= 0 and capacity >= units and
      Enum.all?(inventory, fn item ->
        nonempty?(item.symbol) and is_integer(item.units) and item.units > 0
      end) and Enum.sum(Enum.map(inventory, & &1.units)) == units
  end

  defp valid_cargo?(_), do: false

  defp valid_cooldown?(
         %{
           ship_symbol: symbol,
           remaining_seconds: remaining,
           total_seconds: total,
           expiration: expiration
         },
         symbol
       ),
       do:
         is_integer(remaining) and remaining >= 0 and is_integer(total) and total >= remaining and
           (remaining == 0 or valid_time?(expiration))

  defp valid_cooldown?(_, _), do: false
  defp valid_module?(%{symbol: symbol}), do: nonempty?(symbol)
  defp valid_module?(_), do: false
  defp nonempty?(value), do: is_binary(value) and value != ""

  defp valid_time?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp valid_time?(_), do: false

  defp stringify(%_{} = value), do: value |> Map.from_struct() |> stringify()

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value), do: value
end
