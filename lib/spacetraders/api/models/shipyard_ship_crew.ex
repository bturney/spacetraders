defmodule SpaceTraders.API.Model.ShipyardShipCrew do
  @moduledoc ""

  defstruct [
    :capacity,
    :required
  ]

  @type t :: %__MODULE__{
          capacity: integer(),
          required: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipyardShipCrew`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      capacity: json["capacity"],
      required: json["required"]
    }
  end
end
