defmodule SpaceTraders.SystemMap.Layout do
  @moduledoc """
  Assigns deterministic orbital layout to coordinate-bearing System Map Waypoints.
  """

  @orbital_distance 32

  @doc """
  Returns Waypoints with their orbital layout, parent, and orbital order.

  An Orbital Waypoint whose declared Parent Waypoint is unavailable remains at
  its game-supplied coordinates and is treated as its own parent.
  """
  def position(waypoints) when is_list(waypoints) do
    waypoints = Enum.filter(waypoints, &(is_number(&1.x) and is_number(&1.y)))
    waypoint_symbols = MapSet.new(waypoints, & &1.symbol)

    orbitals_by_parent =
      Enum.group_by(waypoints, &parent_symbol(&1, waypoint_symbols))

    Enum.map(waypoints, fn waypoint ->
      parent_symbol = parent_symbol(waypoint, waypoint_symbols)

      orbitals =
        orbitals_by_parent
        |> Map.get(parent_symbol, [])
        |> Enum.filter(&(&1.orbits == parent_symbol))
        |> Enum.sort_by(& &1.symbol)

      orbital_index = Enum.find_index(orbitals, &(&1.symbol == waypoint.symbol))
      orbital_count = length(orbitals)
      {offset_x, offset_y, orbital_distance} = orbital_offset(orbital_index, orbital_count)

      Map.merge(waypoint, %{
        parent_symbol: parent_symbol,
        orbital_index: orbital_index,
        orbital_count: orbital_count,
        orbital_offset_x: offset_x,
        orbital_offset_y: offset_y,
        orbital_distance: orbital_distance
      })
    end)
  end

  def position(_), do: []

  defp parent_symbol(waypoint, waypoint_symbols) do
    if MapSet.member?(waypoint_symbols, waypoint.orbits),
      do: waypoint.orbits,
      else: waypoint.symbol
  end

  # The browser converts this screen-space distance to SVG units for its active viewport.
  defp orbital_offset(nil, _orbital_count), do: {0.0, 0.0, nil}

  defp orbital_offset(orbital_index, orbital_count) do
    angle = :math.pi() * 2 * orbital_index / orbital_count - :math.pi() / 2

    {
      rounded_coordinate(:math.cos(angle)),
      rounded_coordinate(:math.sin(angle)),
      @orbital_distance
    }
  end

  defp rounded_coordinate(coordinate), do: Float.round(coordinate, 6)
end
