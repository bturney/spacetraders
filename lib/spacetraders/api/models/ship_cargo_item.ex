defmodule SpaceTraders.API.Model.ShipCargoItem do
  @moduledoc "The type of cargo item and the number of units."

  defstruct [
    :description,
    :name,
    :symbol,
    :units
  ]

  @type t :: %__MODULE__{
          description: String.t(),
          name: String.t(),
          symbol: String.t(),
          units: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipCargoItem`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      description: json["description"],
      name: json["name"],
      symbol: json["symbol"],
      units: json["units"]
    }
  end
end
