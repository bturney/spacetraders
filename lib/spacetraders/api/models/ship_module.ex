defmodule SpaceTraders.API.Model.ShipModule do
  @moduledoc "A module can be installed in a ship and provides a set of capabilities such as storage space or quarters for crew. Module installations are permanent."

  defstruct [
    :capacity,
    :description,
    :name,
    :range,
    :requirements,
    :symbol
  ]

  @type t :: %__MODULE__{
          capacity: integer() | nil,
          description: String.t(),
          name: String.t(),
          range: integer() | nil,
          requirements: SpaceTraders.API.Model.ShipRequirements.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipModule`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      capacity: json["capacity"],
      description: json["description"],
      name: json["name"],
      range: json["range"],
      requirements:
        json["requirements"] &&
          SpaceTraders.API.Model.ShipRequirements.from_json(json["requirements"]),
      symbol: json["symbol"]
    }
  end
end
