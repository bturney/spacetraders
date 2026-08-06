defmodule SpaceTraders.API.Model.ShipModificationTransaction do
  @moduledoc "Result of a transaction for a ship modification, such as installing a mount or a module."

  defstruct [
    :ship_symbol,
    :timestamp,
    :total_price,
    :trade_symbol,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          ship_symbol: String.t(),
          timestamp: String.t(),
          total_price: integer(),
          trade_symbol: String.t(),
          waypoint_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipModificationTransaction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      ship_symbol: json["shipSymbol"],
      timestamp: json["timestamp"],
      total_price: json["totalPrice"],
      trade_symbol: json["tradeSymbol"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
