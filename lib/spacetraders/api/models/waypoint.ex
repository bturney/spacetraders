defmodule SpaceTraders.API.Model.Waypoint do
  @moduledoc "A waypoint is a location that ships can travel to such as a Planet, Moon or Space Station."

  defstruct [
    :chart,
    :faction,
    :is_under_construction,
    :modifiers,
    :orbitals,
    :orbits,
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
          is_under_construction: boolean(),
          modifiers: [SpaceTraders.API.Model.WaypointModifier.t()] | nil,
          orbitals: [SpaceTraders.API.Model.WaypointOrbital.t()],
          orbits: String.t() | nil,
          symbol: String.t(),
          system_symbol: String.t(),
          traits: [SpaceTraders.API.Model.WaypointTrait.t()],
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Waypoint`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      chart: json["chart"] && SpaceTraders.API.Model.Chart.from_json(json["chart"]),
      faction:
        json["faction"] && SpaceTraders.API.Model.WaypointFaction.from_json(json["faction"]),
      is_under_construction: json["isUnderConstruction"],
      modifiers:
        Enum.map(json["modifiers"] || [], &SpaceTraders.API.Model.WaypointModifier.from_json/1),
      orbitals:
        Enum.map(json["orbitals"] || [], &SpaceTraders.API.Model.WaypointOrbital.from_json/1),
      orbits: json["orbits"],
      symbol: json["symbol"],
      system_symbol: json["systemSymbol"],
      traits: Enum.map(json["traits"] || [], &SpaceTraders.API.Model.WaypointTrait.from_json/1),
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
