defmodule SpaceTraders.API.Model.ShipFuel do
  @moduledoc "Details of the ship's fuel tanks including how much fuel was consumed during the last transit or action."

  defstruct [
    :capacity,
    :consumed,
    :current
  ]

  @type t :: %__MODULE__{
          capacity: integer(),
          consumed: SpaceTraders.API.Model.ShipFuelConsumed.t() | nil,
          current: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipFuel`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      capacity: json["capacity"],
      consumed:
        json["consumed"] && SpaceTraders.API.Model.ShipFuelConsumed.from_json(json["consumed"]),
      current: json["current"]
    }
  end
end
