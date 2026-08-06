defmodule SpaceTraders.API.Model.ExtractionYield do
  @moduledoc "A yield from the extraction operation."

  defstruct [
    :symbol,
    :units
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          units: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ExtractionYield`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"],
      units: json["units"]
    }
  end
end
