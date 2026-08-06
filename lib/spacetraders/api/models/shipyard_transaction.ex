defmodule SpaceTraders.API.Model.ShipyardTransaction do
  @moduledoc "Results of a transaction with a shipyard."

  defstruct [
    :agent_symbol,
    :price,
    :ship_symbol,
    :ship_type,
    :timestamp,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          agent_symbol: String.t(),
          price: integer(),
          ship_symbol: String.t(),
          ship_type: String.t(),
          timestamp: String.t(),
          waypoint_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipyardTransaction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      agent_symbol: json["agentSymbol"],
      price: json["price"],
      ship_symbol: json["shipSymbol"],
      ship_type: json["shipType"],
      timestamp: json["timestamp"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
