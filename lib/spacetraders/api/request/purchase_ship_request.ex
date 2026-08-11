defmodule SpaceTraders.API.Request.PurchaseShipRequest do
  @moduledoc ""

  defstruct [
    :ship_type,
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          ship_type: String.t(),
          waypoint_symbol: String.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.ship_type), do: raise(ArgumentError, "required field shipType is nil")

    if is_nil(request.waypoint_symbol),
      do: raise(ArgumentError, "required field waypointSymbol is nil")

    %{}
    |> Map.put("shipType", request.ship_type)
    |> Map.put("waypointSymbol", request.waypoint_symbol)
  end
end
