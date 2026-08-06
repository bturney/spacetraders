defmodule SpaceTraders.API.Model.SystemWaypoint do
  @moduledoc "Waypoint details."

  defstruct [
    :orbitals,
    :orbits,
    :symbol,
    :type,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          orbitals: [SpaceTraders.API.Model.WaypointOrbital.t()],
          orbits: String.t() | nil,
          symbol: String.t(),
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.SystemWaypoint`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      orbitals:
        Enum.map(json["orbitals"] || [], &SpaceTraders.API.Model.WaypointOrbital.from_json/1),
      orbits: json["orbits"],
      symbol: json["symbol"],
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
