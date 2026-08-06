defmodule SpaceTraders.API.Model.ShipNavRouteWaypoint do
  @moduledoc "The destination or departure of a ships nav route."

  defstruct [
    :symbol,
    :system_symbol,
    :type,
    :x,
    :y
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          system_symbol: String.t(),
          type: String.t(),
          x: integer(),
          y: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipNavRouteWaypoint`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"],
      system_symbol: json["systemSymbol"],
      type: json["type"],
      x: json["x"],
      y: json["y"]
    }
  end
end
