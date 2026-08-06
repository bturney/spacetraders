defmodule SpaceTraders.API.Model.ShipEngine do
  @moduledoc "The engine determines how quickly a ship travels between waypoints."

  defstruct [
    :condition,
    :description,
    :integrity,
    :name,
    :quality,
    :requirements,
    :speed,
    :symbol
  ]

  @type t :: %__MODULE__{
          condition: float(),
          description: String.t(),
          integrity: float(),
          name: String.t(),
          quality: float(),
          requirements: SpaceTraders.API.Model.ShipRequirements.t(),
          speed: integer(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipEngine`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      condition: json["condition"],
      description: json["description"],
      integrity: json["integrity"],
      name: json["name"],
      quality: json["quality"],
      requirements:
        json["requirements"] &&
          SpaceTraders.API.Model.ShipRequirements.from_json(json["requirements"]),
      speed: json["speed"],
      symbol: json["symbol"]
    }
  end
end
