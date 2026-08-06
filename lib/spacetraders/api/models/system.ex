defmodule SpaceTraders.API.Model.System do
  @moduledoc "System details."

  defstruct [
    :constellation,
    :factions,
    :name,
    :sector_symbol,
    :symbol,
    :type,
    :waypoints,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          constellation: String.t() | nil,
          factions: [SpaceTraders.API.Model.SystemFaction.t()],
          name: String.t() | nil,
          sector_symbol: String.t(),
          symbol: String.t(),
          type: String.t(),
          waypoints: [SpaceTraders.API.Model.SystemWaypoint.t()],
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.System`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      constellation: json["constellation"],
      factions:
        Enum.map(json["factions"] || [], &SpaceTraders.API.Model.SystemFaction.from_json/1),
      name: json["name"],
      sector_symbol: json["sectorSymbol"],
      symbol: json["symbol"],
      type: json["type"],
      waypoints:
        Enum.map(json["waypoints"] || [], &SpaceTraders.API.Model.SystemWaypoint.from_json/1),
      x: json["x"],
      y: json["y"]
    }
  end
end
