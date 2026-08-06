defmodule SpaceTraders.Api.Types.Waypoint do
  @type t :: %__MODULE__{
    symbol: SpaceTraders.Api.Types.WaypointSymbol.t() | nil,
    type: SpaceTraders.Api.Types.WaypointType.t() | nil,
    system_symbol: SpaceTraders.Api.Types.SystemSymbol.t() | nil,
    x: integer(),
    y: integer(),
    orbitals: [SpaceTraders.Api.Types.WaypointOrbital.t()] | nil,
    orbits: String.t(),
    faction: SpaceTraders.Api.Types.WaypointFaction.t() | nil,
    traits: [SpaceTraders.Api.Types.WaypointTrait.t()] | nil,
    modifiers: [SpaceTraders.Api.Types.WaypointModifier.t()] | nil,
    chart: SpaceTraders.Api.Types.Chart.t() | nil,
    is_under_construction: boolean()
  }

  defstruct [
    :symbol,
    :type,
    :system_symbol,
    :x,
    :y,
    :orbitals,
    :orbits,
    :faction,
    :traits,
    :modifiers,
    :chart,
    :is_under_construction
  ]
end
