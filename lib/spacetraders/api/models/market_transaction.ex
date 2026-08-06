defmodule SpaceTraders.API.Model.MarketTransaction do
  @moduledoc "Result of a transaction with a market."

  defstruct [
    :price_per_unit,
    :ship_symbol,
    :timestamp,
    :total_price,
    :trade_symbol,
    :type,
    :units,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          price_per_unit: integer(),
          ship_symbol: String.t(),
          timestamp: String.t(),
          total_price: integer(),
          trade_symbol: String.t(),
          type: String.t(),
          units: integer(),
          waypoint_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.MarketTransaction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      price_per_unit: json["pricePerUnit"],
      ship_symbol: json["shipSymbol"],
      timestamp: json["timestamp"],
      total_price: json["totalPrice"],
      trade_symbol: json["tradeSymbol"],
      type: json["type"],
      units: json["units"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
