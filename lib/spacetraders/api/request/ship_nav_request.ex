defmodule SpaceTraders.API.Request.ShipNavRequest do
  @moduledoc ""

  defstruct [
    :flight_mode
  ]

  @type t :: %__MODULE__{
          flight_mode: String.t() | nil
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    %{}
    |> then(fn json ->
      if is_nil(request.flight_mode),
        do: json,
        else: Map.put(json, "flightMode", request.flight_mode)
    end)
  end
end
