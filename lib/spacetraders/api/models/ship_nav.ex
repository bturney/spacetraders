defmodule SpaceTraders.API.Model.ShipNav do
  @moduledoc "The navigation information of the ship."

  defstruct [
    :flight_mode,
    :route,
    :status,
    :system_symbol,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          flight_mode: String.t(),
          route: SpaceTraders.API.Model.ShipNavRoute.t(),
          status: String.t(),
          system_symbol: String.t(),
          waypoint_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipNav`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      flight_mode: json["flightMode"],
      route: json["route"] && SpaceTraders.API.Model.ShipNavRoute.from_json(json["route"]),
      status: json["status"],
      system_symbol: json["systemSymbol"],
      waypoint_symbol: json["waypointSymbol"]
    }
  end
end
