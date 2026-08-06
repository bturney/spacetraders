defmodule SpaceTraders.API.Model.ConnectedSystem do
  @moduledoc ""

  defstruct [
    :distance,
    :faction_symbol,
    :sector_symbol,
    :symbol,
    :type,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          distance: integer(),
          faction_symbol: String.t() | nil,
          sector_symbol: String.t(),
          symbol: String.t(),
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ConnectedSystem`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      distance: json["distance"],
      faction_symbol: json["factionSymbol"],
      sector_symbol: json["sectorSymbol"],
      symbol: json["symbol"],
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
