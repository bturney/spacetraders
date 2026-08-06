defmodule SpaceTraders.API.Model.ShipNavRoute do
  @moduledoc "The routing information for the ship's most recent transit or current location."

  defstruct [
    :arrival,
    :departure_time,
    :destination,
    :origin
  ]

  @type t :: %__MODULE__{
          arrival: String.t(),
          departure_time: String.t(),
          destination: SpaceTraders.API.Model.ShipNavRouteWaypoint.t(),
          origin: SpaceTraders.API.Model.ShipNavRouteWaypoint.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipNavRoute`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      arrival: json["arrival"],
      departure_time: json["departureTime"],
      destination:
        json["destination"] &&
          SpaceTraders.API.Model.ShipNavRouteWaypoint.from_json(json["destination"]),
      origin:
        json["origin"] && SpaceTraders.API.Model.ShipNavRouteWaypoint.from_json(json["origin"])
    }
  end
end
