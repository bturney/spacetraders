defmodule SpaceTraders.API.Model.ScannedWaypoint do
  @moduledoc "A waypoint that was scanned by a ship."

  defstruct [
    :chart,
    :faction,
    :orbitals,
    :symbol,
    :system_symbol,
    :traits,
    :type,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          chart: SpaceTraders.API.Model.Chart.t() | nil,
          faction: SpaceTraders.API.Model.WaypointFaction.t() | nil,
          orbitals: [SpaceTraders.API.Model.WaypointOrbital.t()],
          symbol: String.t(),
          system_symbol: String.t(),
          traits: [SpaceTraders.API.Model.WaypointTrait.t()],
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScannedWaypoint`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      chart: json["chart"] && SpaceTraders.API.Model.Chart.from_json(json["chart"]),
      faction:
        json["faction"] && SpaceTraders.API.Model.WaypointFaction.from_json(json["faction"]),
      orbitals:
        Enum.map(json["orbitals"] || [], &SpaceTraders.API.Model.WaypointOrbital.from_json/1),
      symbol: json["symbol"],
      system_symbol: json["systemSymbol"],
      traits: Enum.map(json["traits"] || [], &SpaceTraders.API.Model.WaypointTrait.from_json/1),
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
