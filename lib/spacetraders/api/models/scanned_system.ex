defmodule SpaceTraders.API.Model.ScannedSystem do
  @moduledoc "Details of a system was that scanned."

  defstruct [
    :distance,
    :sector_symbol,
    :symbol,
    :type,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          distance: integer(),
          sector_symbol: String.t(),
          symbol: String.t(),
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScannedSystem`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      distance: json["distance"],
      sector_symbol: json["sectorSymbol"],
      symbol: json["symbol"],
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
