defmodule SpaceTraders.API.Model.Market do
  @moduledoc "Market details."

  defstruct [
    :exchange,
    :exports,
    :imports,
    :symbol,
    :trade_goods,
    :transactions
  ]

  @type t :: %__MODULE__{
          exchange: [SpaceTraders.API.Model.TradeGood.t()],
          exports: [SpaceTraders.API.Model.TradeGood.t()],
          imports: [SpaceTraders.API.Model.TradeGood.t()],
          symbol: String.t(),
          trade_goods: [SpaceTraders.API.Model.MarketTradeGood.t()] | nil,
          transactions: [SpaceTraders.API.Model.MarketTransaction.t()] | nil
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Market`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      exchange: Enum.map(json["exchange"] || [], &SpaceTraders.API.Model.TradeGood.from_json/1),
      exports: Enum.map(json["exports"] || [], &SpaceTraders.API.Model.TradeGood.from_json/1),
      imports: Enum.map(json["imports"] || [], &SpaceTraders.API.Model.TradeGood.from_json/1),
      symbol: json["symbol"],
      trade_goods:
        Enum.map(json["tradeGoods"] || [], &SpaceTraders.API.Model.MarketTradeGood.from_json/1),
      transactions:
        Enum.map(
          json["transactions"] || [],
          &SpaceTraders.API.Model.MarketTransaction.from_json/1
        )
    }
  end
end
