defmodule SpaceTraders.API.Request.InstallShipModuleRequest do
  @moduledoc ""

  defstruct [
    :symbol
  ]

  @type t :: %__MODULE__{
          symbol: String.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.symbol), do: raise(ArgumentError, "required field symbol is nil")

    %{}
    |> Map.put("symbol", request.symbol)
  end
end
