defmodule SpaceTraders.API.Model.ShipRole do
  @moduledoc "The registered role of the ship"

  @type t :: String.t()
  @enums [
    "FABRICATOR",
    "HARVESTER",
    "HAULER",
    "INTERCEPTOR",
    "EXCAVATOR",
    "TRANSPORT",
    "REPAIR",
    "SURVEYOR",
    "COMMAND",
    "CARRIER",
    "PATROL",
    "SATELLITE",
    "EXPLORER",
    "REFINERY"
  ]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
