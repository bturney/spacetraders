defmodule SpaceTraders.API.Model.ShipCrew do
  @moduledoc "The ship's crew service and maintain the ship's systems and equipment."

  defstruct [
    :capacity,
    :current,
    :morale,
    :required,
    :rotation,
    :wages
  ]

  @type t :: %__MODULE__{
          capacity: integer(),
          current: integer(),
          morale: integer(),
          required: integer(),
          rotation: String.t(),
          wages: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipCrew`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      capacity: json["capacity"],
      current: json["current"],
      morale: json["morale"],
      required: json["required"],
      rotation: json["rotation"],
      wages: json["wages"]
    }
  end
end
