defmodule SpaceTraders.API.Model.WaypointOrbital do
  @moduledoc "An orbital is another waypoint that orbits a parent waypoint."

  defstruct [
    :symbol
  ]

  @type t :: %__MODULE__{
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.WaypointOrbital`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"]
    }
  end
end
