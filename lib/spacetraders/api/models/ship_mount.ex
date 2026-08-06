defmodule SpaceTraders.API.Model.ShipMount do
  @moduledoc "A mount is installed on the exterier of a ship."

  defstruct [
    :deposits,
    :description,
    :name,
    :requirements,
    :strength,
    :symbol
  ]

  @type t :: %__MODULE__{
          deposits: [String.t()] | nil,
          description: String.t() | nil,
          name: String.t(),
          requirements: SpaceTraders.API.Model.ShipRequirements.t(),
          strength: integer() | nil,
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipMount`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      deposits: json["deposits"] || [],
      description: json["description"],
      name: json["name"],
      requirements:
        json["requirements"] &&
          SpaceTraders.API.Model.ShipRequirements.from_json(json["requirements"]),
      strength: json["strength"],
      symbol: json["symbol"]
    }
  end
end
