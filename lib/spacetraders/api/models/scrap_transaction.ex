defmodule SpaceTraders.API.Model.ScrapTransaction do
  @moduledoc "Result of a scrap transaction."

  defstruct [
    :ship_symbol,
    :timestamp,
    :total_price,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          ship_symbol: String.t(),
          timestamp: String.t(),
          total_price: integer(),
          waypoint_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScrapTransaction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      ship_symbol: json["shipSymbol"],
      timestamp: json["timestamp"],
      total_price: json["totalPrice"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
