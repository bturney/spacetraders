defmodule SpaceTraders.API.Model.ShipType do
  @moduledoc "Type of ship"

  @type t :: String.t()
  @enums [
    "SHIP_PROBE",
    "SHIP_MINING_DRONE",
    "SHIP_SIPHON_DRONE",
    "SHIP_INTERCEPTOR",
    "SHIP_LIGHT_HAULER",
    "SHIP_COMMAND_FRIGATE",
    "SHIP_EXPLORER",
    "SHIP_HEAVY_FREIGHTER",
    "SHIP_LIGHT_SHUTTLE",
    "SHIP_ORE_HOUND",
    "SHIP_REFINING_FREIGHTER",
    "SHIP_SURVEYOR",
    "SHIP_BULK_FREIGHTER"
  ]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
