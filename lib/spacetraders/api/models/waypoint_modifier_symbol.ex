defmodule SpaceTraders.API.Model.WaypointModifierSymbol do
  @moduledoc "The unique identifier of the modifier."

  @type t :: String.t()
  @enums ["STRIPPED", "UNSTABLE", "RADIATION_LEAK", "CRITICAL_LIMIT", "CIVIL_UNREST"]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
