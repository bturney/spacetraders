defmodule SpaceTraders.API.Model.SupplyLevel do
  @moduledoc "The supply level of a trade good."

  @type t :: String.t()
  @enums ["SCARCE", "LIMITED", "MODERATE", "HIGH", "ABUNDANT"]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
