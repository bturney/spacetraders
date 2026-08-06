defmodule SpaceTraders.API.Model.SiphonYield do
  @moduledoc "A yield from the siphon operation."

  defstruct [
    :symbol,
    :units
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          units: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.SiphonYield`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"],
      units: json["units"]
    }
  end
end
