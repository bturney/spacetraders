defmodule SpaceTraders.API.Request.JettisonCargoRequest do
  @moduledoc ""

  defstruct [
    :symbol,
    :units
  ]

  @type t :: %__MODULE__{
          symbol: String.t(),
          units: integer()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.symbol), do: raise(ArgumentError, "required field symbol is nil")
    if is_nil(request.units), do: raise(ArgumentError, "required field units is nil")

    %{}
    |> Map.put("symbol", request.symbol)
    |> Map.put("units", request.units)
  end
end
