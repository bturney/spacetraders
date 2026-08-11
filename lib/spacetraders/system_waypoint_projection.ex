defmodule SpaceTraders.SystemWaypointProjection do
  @moduledoc """
  Projects one System's Waypoints and the Agent's Fleet state for the linked
  System Map and Waypoint Grid.

  One deterministic call turns already-read Fleet snapshots and interaction
  inputs into the shared Waypoint state both views render: grid rows, filters,
  per-Waypoint ship counts and the selected Waypoint — plus, for the System Map
  alone, coordinates, orbital stacking, and Transit Routes. LiveView keeps
  selection and filter event state and passes it in; the browser adapter keeps
  pan, zoom, and inspector placement.

  Unavailable data stays explicit: a failed Waypoint read is preserved in the
  result, and a failed Ship read surfaces as `:unavailable` in `:ships_at`, so
  callers can render the reason instead of silently substituting empty state.
  """

  alias SpaceTraders.API.Model
  alias SpaceTraders.SystemMap.Layout

  @typedoc "The read result of one System's Waypoints"
  @type waypoints :: {:ok, [Model.Waypoint.t()]} | {:error, term()}

  @typedoc "The read result of the Agent's Fleet"
  @type ships :: {:ok, [Model.Ship.t()]} | {:error, term()}

  @typedoc "A Waypoint carrying its orbital stacking metadata, for the System Map"
  @type positioned_waypoint :: Model.Waypoint.t()

  @typedoc "One active Transit Route with its positioned endpoint Waypoints"
  @type transit_route :: %{
          ship: Model.Ship.t(),
          origin: Model.Waypoint.t(),
          destination: Model.Waypoint.t()
        }

  @typedoc "The projected state for the System Map and Waypoint Grid"
  @type t :: %{
          waypoints: waypoints(),
          available: [Model.Waypoint.t()],
          filtered: [Model.Waypoint.t()],
          positioned: [positioned_waypoint()],
          selected: Model.Waypoint.t() | nil,
          ships_at: %{String.t() => [Model.Ship.t()]} | :unavailable,
          transit_routes: [transit_route()],
          off_system: [Model.Ship.t()],
          inter_system_transit: [Model.Ship.t()]
        }

  @doc """
  Projects Waypoint and Fleet state for the System Map and Waypoint Grid.

  ## Inputs

  - `waypoints` — the System's Waypoints, as read by the Fleet context.
  - `ships` — the Agent's Fleet, as read by the Fleet context.
  - `system_symbol` — the System being shown (derived from the Agent's
    headquarters Waypoint).
  - `selected_symbol` — the Waypoint selected in either linked view.
  - `filter` — the active grid filter, one of the values in `filter_options/0`.

  ## Result

  A single projection with the shared Waypoint state (`:available`,
  `:filtered`, `:selected`, `:ships_at`) plus System Map-only state
  (`:positioned`, `:transit_routes`, `:off_system`, `:inter_system_transit`).
  The Waypoint read result is preserved so callers can render its
  unavailability; a failed Ship read shows as `:unavailable` in `:ships_at`.
  """
  @spec project(
          waypoints(),
          ships(),
          String.t() | nil,
          String.t() | nil,
          String.t()
        ) :: t()
  def project(waypoints, ships, system_symbol, selected_symbol \\ nil, filter \\ "all")

  def project({:ok, waypoints}, ships, system_symbol, selected_symbol, filter)
      when is_list(waypoints) do
    %{
      waypoints: {:ok, waypoints},
      available: waypoints,
      filtered: filtered_waypoints(waypoints, filter),
      positioned: positioned_waypoints(waypoints),
      selected: selected_waypoint(waypoints, selected_symbol),
      ships_at: ships_at(ships, waypoints),
      transit_routes: transit_routes(ships, waypoints, system_symbol),
      off_system: off_system_ships(ships, system_symbol),
      inter_system_transit: inter_system_transit_ships(ships)
    }
  end

  def project(waypoints, _ships, _system_symbol, _selected_symbol, _filter) do
    %{
      waypoints: waypoints,
      available: [],
      filtered: [],
      positioned: [],
      selected: nil,
      ships_at: :unavailable,
      transit_routes: [],
      off_system: [],
      inter_system_transit: []
    }
  end

  @doc """
  The selectable Waypoint Grid filters, as `{label, value}` pairs.

  The grid renders these options and `project/5` interprets their values, so
  the filter vocabulary has a single owner.
  """
  @spec filter_options() :: [{String.t(), String.t()}]
  def filter_options do
    [
      {"All types", "all"},
      {"Engineered asteroids", "engineered_asteroid"},
      {"Shipyards", "shipyard"},
      {"Marketplaces", "marketplace"}
    ]
  end

  defp positioned_waypoints(waypoints) do
    Layout.position(waypoints)
  end

  defp filtered_waypoints(waypoints, "engineered_asteroid"),
    do: Enum.filter(waypoints, &(&1.type == "ENGINEERED_ASTEROID"))

  defp filtered_waypoints(waypoints, "shipyard"),
    do: Enum.filter(waypoints, &has_trait?(&1, "SHIPYARD"))

  defp filtered_waypoints(waypoints, "marketplace"),
    do: Enum.filter(waypoints, &has_trait?(&1, "MARKETPLACE"))

  defp filtered_waypoints(waypoints, _filter), do: waypoints

  defp has_trait?(waypoint, trait), do: Enum.any?(waypoint.traits || [], &(&1.symbol == trait))

  defp ships_at({:ok, ships}, waypoints) when is_list(ships) do
    Map.new(waypoints, fn waypoint ->
      {waypoint.symbol, local_ships_at_waypoint(ships, waypoint.symbol, waypoint.system_symbol)}
    end)
  end

  defp ships_at(_ships, _waypoints), do: :unavailable

  defp local_ships_at_waypoint(ships, waypoint_symbol, system_symbol) do
    Enum.filter(ships, fn ship ->
      not in_transit?(ship) and ship_location(ship) == waypoint_symbol and
        ship_system(ship) == system_symbol
    end)
  end

  defp transit_routes({:ok, ships}, waypoints, system_symbol) when is_list(ships) do
    waypoint_by_symbol = Map.new(waypoints, &{&1.symbol, &1})

    for ship <- ships,
        %{origin: origin, destination: destination} <- [ship.nav.route],
        origin.system_symbol == system_symbol,
        destination.system_symbol == system_symbol,
        origin_waypoint = Map.get(waypoint_by_symbol, origin.symbol),
        destination_waypoint = Map.get(waypoint_by_symbol, destination.symbol),
        positioned?(origin_waypoint),
        positioned?(destination_waypoint),
        in_transit?(ship) do
      %{ship: ship, origin: origin_waypoint, destination: destination_waypoint}
    end
  end

  defp transit_routes(_ships, _waypoints, _system_symbol), do: []

  defp positioned?(waypoint),
    do: is_map(waypoint) and is_integer(waypoint.x) and is_integer(waypoint.y)

  defp off_system_ships({:ok, ships}, system_symbol) when is_list(ships) do
    Enum.filter(ships, fn ship ->
      (not in_transit?(ship) and ship_system(ship) != system_symbol) or
        (in_transit?(ship) and remote_local_transit?(ship, system_symbol))
    end)
  end

  defp off_system_ships(_ships, _system_symbol), do: []

  defp inter_system_transit_ships({:ok, ships}) when is_list(ships) do
    Enum.filter(ships, &(in_transit?(&1) and inter_system_transit?(&1)))
  end

  defp inter_system_transit_ships(_ships), do: []

  defp remote_local_transit?(
         %{nav: %{route: %{origin: origin, destination: destination}}},
         system_symbol
       ) do
    origin.system_symbol == destination.system_symbol and origin.system_symbol != system_symbol
  end

  defp remote_local_transit?(_ship, _system_symbol), do: false

  defp inter_system_transit?(%{nav: %{route: %{origin: origin, destination: destination}}}) do
    origin.system_symbol != destination.system_symbol
  end

  defp inter_system_transit?(_ship), do: true

  defp ship_system(%{nav: %{system_symbol: system_symbol}}), do: system_symbol
  defp ship_system(_ship), do: nil

  defp in_transit?(%{nav: %{status: "IN_TRANSIT"}}), do: true
  defp in_transit?(_ship), do: false

  defp ship_location(%{nav: %{waypoint_symbol: waypoint}}) when is_binary(waypoint),
    do: waypoint

  defp ship_location(_ship), do: nil

  defp selected_waypoint(waypoints, symbol), do: Enum.find(waypoints, &(&1.symbol == symbol))
end
