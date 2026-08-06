defmodule SpaceTraders.API.Model.ActivityLevel do
  @moduledoc "The activity level of a trade good. If the good is an import, this represents how strong consumption is. If the good is an export, this represents how strong the production is for the good. When activity is strong, consumption or production is near maximum capacity. When activity is weak, consumption or production is near minimum capacity."

  @type t :: String.t()
  @enums ["WEAK", "GROWING", "STRONG", "RESTRICTED"]

  @doc "All valid values."
  @spec values() :: [t()]
  def values, do: @enums
end
