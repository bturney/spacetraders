defmodule SpaceTraders.API.Model.ShipNavFlightMode do
  @moduledoc "The ship's set speed when traveling between waypoints or systems."

  @type t :: String.t()
  @enums ["DRIFT", "STEALTH", "CRUISE", "BURN"]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
