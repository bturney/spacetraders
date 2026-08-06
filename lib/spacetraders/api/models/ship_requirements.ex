defmodule SpaceTraders.API.Model.ShipRequirements do
  @moduledoc "The requirements for installation on a ship"

  defstruct [
    :crew,
    :power,
    :slots
  ]

  @type t :: %__MODULE__{
          crew: integer() | nil,
          power: integer() | nil,
          slots: integer() | nil
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipRequirements`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      crew: json["crew"],
      power: json["power"],
      slots: json["slots"]
    }
  end
end
