defmodule SpaceTraders.API.Model.MarketTradeGood do
  @moduledoc ""

  defstruct [
    :activity,
    :purchase_price,
    :sell_price,
    :supply,
    :symbol,
    :trade_volume,
    :type
  ]

  @type t :: %__MODULE__{
          activity: String.t() | nil,
          purchase_price: integer(),
          sell_price: integer(),
          supply: String.t(),
          symbol: String.t(),
          trade_volume: integer(),
          type: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.MarketTradeGood`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      activity: json["activity"],
      purchase_price: json["purchasePrice"],
      sell_price: json["sellPrice"],
      supply: json["supply"],
      symbol: json["symbol"],
      trade_volume: json["tradeVolume"],
      type: json["type"]
    }
  end
end
