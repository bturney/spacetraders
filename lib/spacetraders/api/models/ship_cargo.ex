defmodule SpaceTraders.API.Model.ShipCargo do
  @moduledoc "Ship cargo details."

  defstruct [
    :capacity,
    :inventory,
    :units
  ]

  @type t :: %__MODULE__{
          capacity: integer(),
          inventory: [SpaceTraders.API.Model.ShipCargoItem.t()],
          units: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipCargo`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      capacity: json["capacity"],
      inventory:
        Enum.map(json["inventory"] || [], &SpaceTraders.API.Model.ShipCargoItem.from_json/1),
      units: json["units"]
    }
  end
end
