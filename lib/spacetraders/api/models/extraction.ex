defmodule SpaceTraders.API.Model.Extraction do
  @moduledoc "Extraction details."

  defstruct [
    :ship_symbol,
    :yield
  ]

  @type t :: %__MODULE__{
          ship_symbol: String.t(),
          yield: SpaceTraders.API.Model.ExtractionYield.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Extraction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      ship_symbol: json["shipSymbol"],
      yield: json["yield"] && SpaceTraders.API.Model.ExtractionYield.from_json(json["yield"])
    }
  end
end
