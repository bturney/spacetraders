defmodule SpaceTraders.API.Model.WaypointType do
  @moduledoc "The type of waypoint."

  @type t :: String.t()
  @enums [
    "PLANET",
    "GAS_GIANT",
    "MOON",
    "ORBITAL_STATION",
    "JUMP_GATE",
    "ASTEROID_FIELD",
    "ASTEROID",
    "ENGINEERED_ASTEROID",
    "ASTEROID_BASE",
    "NEBULA",
    "DEBRIS_FIELD",
    "GRAVITY_WELL",
    "ARTIFICIAL_GRAVITY_WELL",
    "FUEL_STATION"
  ]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
