defmodule SpaceTraders.API.Request.SupplyConstructionRequest do
  @moduledoc ""

  defstruct [
    :ship_symbol,
    :trade_symbol,
    :units
  ]

  @type t :: %__MODULE__{
          ship_symbol: String.t(),
          trade_symbol: String.t(),
          units: integer()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.ship_symbol), do: raise(ArgumentError, "required field shipSymbol is nil")
    if is_nil(request.trade_symbol), do: raise(ArgumentError, "required field tradeSymbol is nil")
    if is_nil(request.units), do: raise(ArgumentError, "required field units is nil")

    %{}
    |> Map.put("shipSymbol", request.ship_symbol)
    |> Map.put("tradeSymbol", request.trade_symbol)
    |> Map.put("units", request.units)
  end
end
