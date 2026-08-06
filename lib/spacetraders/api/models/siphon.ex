defmodule SpaceTraders.API.Model.Siphon do
  @moduledoc "Siphon details."

  defstruct [
    :ship_symbol,
    :yield
  ]

  @type t :: %__MODULE__{
          ship_symbol: String.t(),
          yield: SpaceTraders.API.Model.SiphonYield.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Siphon`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      ship_symbol: json["shipSymbol"],
      yield: json["yield"] && SpaceTraders.API.Model.SiphonYield.from_json(json["yield"])
    }
  end
end
