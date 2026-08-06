defmodule SpaceTraders.API.Model.ShipNavStatus do
  @moduledoc "The current status of the ship"

  @type t :: String.t()
  @enums ["IN_TRANSIT", "IN_ORBIT", "DOCKED"]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
