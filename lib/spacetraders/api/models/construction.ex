defmodule SpaceTraders.API.Model.Construction do
  @moduledoc "The construction details of a waypoint."

  defstruct [
    :is_complete,
    :materials,
    :symbol
  ]

  @type t :: %__MODULE__{
          is_complete: boolean(),
          materials: [SpaceTraders.API.Model.ConstructionMaterial.t()],
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Construction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      is_complete: json["isComplete"],
      materials:
        Enum.map(
          json["materials"] || [],
          &SpaceTraders.API.Model.ConstructionMaterial.from_json/1
        ),
      symbol: json["symbol"]
    }
  end
end
