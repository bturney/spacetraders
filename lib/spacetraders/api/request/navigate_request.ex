defmodule SpaceTraders.API.Request.NavigateRequest do
  @moduledoc ""

  defstruct [
    :waypoint_symbol
  ]

  @type t :: %__MODULE__{
          waypoint_symbol: String.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.waypoint_symbol),
      do: raise(ArgumentError, "required field waypointSymbol is nil")

    %{}
    |> Map.put("waypointSymbol", request.waypoint_symbol)
  end
end
