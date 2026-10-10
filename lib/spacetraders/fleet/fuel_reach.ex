defmodule SpaceTraders.Fleet.FuelReach do
  @moduledoc """
  The one fuel-reach rule shared by Fleet Planning and Ship Execution.

  Ship Execution flies one in-System leg like this: go when the tank covers
  it; otherwise, when the leg fits the tank, refuel in place where FUEL is
  sold; otherwise detour to the nearest known fuel stop the tank reaches now
  that is nearer the target, and repeat from there. `fuel_stop/4` is that
  detour choice, and `arrival_fuel/4` simulates the whole leg so Fleet
  Planning proposes only what Execution would fly.

  Fuel stops come from `SpaceTraders.World.fuel_stops/3` on both sides.
  Everything here is pure.
  """

  @enforce_keys [:capacity, :flight_mode, :coordinates, :stops]
  defstruct [:capacity, :flight_mode, :coordinates, :stops]

  @typedoc "A Ship's tank and flight mode against known coordinates and fuel stops."
  @type t :: %__MODULE__{
          capacity: non_neg_integer(),
          flight_mode: String.t() | nil,
          coordinates: %{String.t() => %{x: integer(), y: integer()}},
          stops: MapSet.t(String.t())
        }

  def new(capacity, flight_mode, coordinates, stops) do
    %__MODULE__{
      capacity: capacity,
      flight_mode: flight_mode,
      coordinates: coordinates,
      stops: MapSet.new(stops)
    }
  end

  @doc "Estimated fuel for one leg between two points at a flight mode."
  def estimate(%{x: x1, y: y1}, %{x: x2, y: y2}, flight_mode)
      when is_integer(x1) and is_integer(y1) and is_integer(x2) and is_integer(y2) do
    distance = :math.sqrt(:math.pow(x1 - x2, 2) + :math.pow(y1 - y2, 2)) |> round()

    case flight_mode do
      mode when mode in ["CRUISE", "STEALTH"] -> {:ok, max(1, distance)}
      "DRIFT" -> {:ok, 1}
      "BURN" -> {:ok, max(2, distance * 2)}
      _ -> {:error, :flight_mode_unavailable}
    end
  end

  def estimate(_source, _target, _flight_mode),
    do: {:error, :navigation_coordinates_unavailable}

  @doc "Where a live Ship is: its current Waypoint with route coordinates."
  def position(%{nav: %{waypoint_symbol: waypoint, route: %{} = route}})
      when is_binary(waypoint) do
    case Enum.find([route.destination, route.origin], &(&1 && &1.symbol == waypoint)) do
      %{x: x, y: y} when is_integer(x) and is_integer(y) ->
        {:ok, %{symbol: waypoint, x: x, y: y}}

      _ ->
        {:error, :current_coordinates_unavailable}
    end
  end

  def position(_ship), do: {:error, :current_coordinates_unavailable}

  @doc """
  The nearest known fuel stop reachable from `source` (`%{symbol, x, y}`) on
  `fuel` that is nearer `target` than `source` is, skipping `visited`.
  """
  def fuel_stop(%__MODULE__{} = reach, source, fuel, target, visited \\ []) do
    with {:ok, target_required} <- estimate(source, target, reach.flight_mode) do
      visited = MapSet.new(visited)

      reach.stops
      |> Enum.flat_map(fn stop ->
        with false <- stop == source.symbol or MapSet.member?(visited, stop),
             %{x: _, y: _} = point <- reach.coordinates[stop],
             {:ok, required} <- estimate(source, point, reach.flight_mode),
             true <- required <= fuel,
             {:ok, remaining} <- estimate(point, target, reach.flight_mode),
             true <- remaining < target_required do
          [{required, stop}]
        else
          _ -> []
        end
      end)
      |> Enum.min(fn -> nil end)
      |> case do
        {required, stop} -> {:ok, stop, required}
        nil -> :none
      end
    else
      _ -> :none
    end
  end

  @doc """
  Fuel left on arriving at `to` from `from` holding `fuel`, flown the way
  Ship Execution flies it; `:unreachable` when Execution would refuse the
  leg, `:unknown` without the coordinates or flight mode to judge it.
  """
  def arrival_fuel(%__MODULE__{capacity: capacity}, _from, fuel, _to) when capacity <= 0,
    do: fuel

  def arrival_fuel(%__MODULE__{} = reach, from, fuel, to) do
    with %{} = origin <- reach.coordinates[from],
         %{} = target <- reach.coordinates[to],
         {:ok, _} <- estimate(origin, target, reach.flight_mode) do
      fly(reach, Map.put(origin, :symbol, from), fuel, Map.put(target, :symbol, to), [])
    else
      _ -> :unknown
    end
  end

  defp fly(_reach, %{symbol: symbol}, fuel, %{symbol: symbol}, _visited), do: fuel

  defp fly(reach, here, fuel, target, visited) do
    {:ok, required} = estimate(here, target, reach.flight_mode)

    cond do
      fuel >= required ->
        fuel - required

      required <= reach.capacity and MapSet.member?(reach.stops, here.symbol) ->
        reach.capacity - required

      true ->
        detour(reach, here, fuel, target, visited)
    end
  end

  defp detour(reach, here, fuel, target, visited) do
    case fuel_stop(reach, here, fuel, target, visited) do
      {:ok, stop, required} ->
        point = Map.put(reach.coordinates[stop], :symbol, stop)
        fly(reach, point, fuel - required, target, [stop | visited])

      :none ->
        :unreachable
    end
  end
end
