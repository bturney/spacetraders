defmodule SpaceTraders.SystemMap.LayoutTest do
  use ExUnit.Case, async: true

  alias SpaceTraders.SystemMap.Layout

  test "lays out Orbitals around an available Parent in symbol order" do
    waypoints = [
      %{symbol: "PARENT", x: 10, y: 20, orbits: nil},
      %{symbol: "MOON-B", x: 10, y: 20, orbits: "PARENT"},
      %{symbol: "MOON-A", x: 10, y: 20, orbits: "PARENT"}
    ]

    positioned = Layout.position(waypoints)

    assert %{parent_symbol: "PARENT", orbital_count: 2, orbital_index: nil, orbital_distance: nil} =
             waypoint(positioned, "PARENT")

    assert %{
             parent_symbol: "PARENT",
             orbital_count: 2,
             orbital_index: 0,
             orbital_offset_x: first_offset_x,
             orbital_offset_y: -1.0,
             orbital_distance: 32
           } = waypoint(positioned, "MOON-A")

    assert first_offset_x == 0.0

    assert %{
             parent_symbol: "PARENT",
             orbital_count: 2,
             orbital_index: 1,
             orbital_offset_x: second_offset_x,
             orbital_offset_y: 1.0,
             orbital_distance: 32
           } = waypoint(positioned, "MOON-B")

    assert second_offset_x == 0.0
  end

  test "leaves an Orbital at its supplied coordinates when its Parent is unavailable" do
    [waypoint] = Layout.position([%{symbol: "MOON", x: 4, y: 9, orbits: "MISSING"}])

    assert %{x: 4, y: 9, parent_symbol: "MOON", orbital_count: 0, orbital_index: nil} = waypoint
  end

  test "assigns compass directions from symbol order regardless of input order" do
    positioned =
      Layout.position([
        %{symbol: "PARENT", x: 0, y: 0, orbits: nil},
        %{symbol: "MOON-D", x: 0, y: 0, orbits: "PARENT"},
        %{symbol: "MOON-C", x: 0, y: 0, orbits: "PARENT"},
        %{symbol: "MOON-B", x: 0, y: 0, orbits: "PARENT"},
        %{symbol: "MOON-A", x: 0, y: 0, orbits: "PARENT"}
      ])

    offsets =
      positioned
      |> Enum.filter(&(&1.orbits == "PARENT"))
      |> Enum.sort_by(& &1.symbol)
      |> Enum.map(&{&1.symbol, {&1.orbital_offset_x, &1.orbital_offset_y}})

    assert offsets == [
             {"MOON-A", {0.0, -1.0}},
             {"MOON-B", {1.0, 0.0}},
             {"MOON-C", {0.0, 1.0}},
             {"MOON-D", {-1.0, 0.0}}
           ]
  end

  defp waypoint(waypoints, symbol), do: Enum.find(waypoints, &(&1.symbol == symbol))
end
