defmodule SpaceTraders.API.Model.ShipFrame do
  @moduledoc "The frame of the ship. The frame determines the number of modules and mounting points of the ship, as well as base fuel capacity. As the condition of the frame takes more wear, the ship will become more sluggish and less maneuverable."

  defstruct [
    :condition,
    :description,
    :fuel_capacity,
    :integrity,
    :module_slots,
    :mounting_points,
    :name,
    :quality,
    :requirements,
    :symbol
  ]

  @type t :: %__MODULE__{
          condition: float(),
          description: String.t(),
          fuel_capacity: integer(),
          integrity: float(),
          module_slots: integer(),
          mounting_points: integer(),
          name: String.t(),
          quality: float(),
          requirements: SpaceTraders.API.Model.ShipRequirements.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipFrame`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      condition: json["condition"],
      description: json["description"],
      fuel_capacity: json["fuelCapacity"],
      integrity: json["integrity"],
      module_slots: json["moduleSlots"],
      mounting_points: json["mountingPoints"],
      name: json["name"],
      quality: json["quality"],
      requirements:
        json["requirements"] &&
          SpaceTraders.API.Model.ShipRequirements.from_json(json["requirements"]),
      symbol: json["symbol"]
    }
  end
end
