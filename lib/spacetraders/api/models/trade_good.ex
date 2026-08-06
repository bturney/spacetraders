defmodule SpaceTraders.API.Model.TradeGood do
  @moduledoc "A good that can be traded for other goods or currency."

  defstruct [
    :description,
    :name,
    :symbol
  ]

  @type t :: %__MODULE__{
          description: String.t(),
          name: String.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.TradeGood`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      description: json["description"],
      name: json["name"],
      symbol: json["symbol"]
    }
  end
end
