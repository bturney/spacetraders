defmodule SpaceTraders.Api.Types.SystemWaypoint do
  @type t :: %__MODULE__{
    symbol: SpaceTraders.Api.Types.WaypointSymbol.t() | nil,
    type: SpaceTraders.Api.Types.WaypointType.t() | nil,
    x: integer(),
    y: integer(),
    orbitals: [SpaceTraders.Api.Types.WaypointOrbital.t()] | nil,
    orbits: String.t()
  }

  defstruct [
    :symbol,
    :type,
    :x,
    :y,
    :orbitals,
    :orbits
  ]
end
