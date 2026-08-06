defmodule SpaceTraders.API.Model.ShipReactor do
  @moduledoc "The reactor of the ship. The reactor is responsible for powering the ship's systems and weapons."

  defstruct [
    :condition,
    :description,
    :integrity,
    :name,
    :power_output,
    :quality,
    :requirements,
    :symbol
  ]

  @type t :: %__MODULE__{
          condition: float(),
          description: String.t(),
          integrity: float(),
          name: String.t(),
          power_output: integer(),
          quality: float(),
          requirements: SpaceTraders.API.Model.ShipRequirements.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipReactor`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      condition: json["condition"],
      description: json["description"],
      integrity: json["integrity"],
      name: json["name"],
      power_output: json["powerOutput"],
      quality: json["quality"],
      requirements:
        json["requirements"] &&
          SpaceTraders.API.Model.ShipRequirements.from_json(json["requirements"]),
      symbol: json["symbol"]
    }
  end
end
