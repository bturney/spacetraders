defmodule SpaceTraders.API.Model.SystemType do
  @moduledoc "The type of system."

  @type t :: String.t()
  @enums [
    "NEUTRON_STAR",
    "RED_STAR",
    "ORANGE_STAR",
    "BLUE_STAR",
    "YOUNG_STAR",
    "WHITE_DWARF",
    "BLACK_HOLE",
    "HYPERGIANT",
    "NEBULA",
    "UNSTABLE"
  ]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
