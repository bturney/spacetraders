defmodule SpaceTraders.API.Request.RegisterRequest do
  @moduledoc ""

  defstruct [
    :email,
    :faction,
    :symbol
  ]

  @type t :: %__MODULE__{
          email: String.t() | nil,
          faction: String.t(),
          symbol: String.t()
        }

  @spec new(map()) :: t()
  def new(attrs) when is_map(attrs), do: struct!(__MODULE__, attrs)

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = request) do
    if is_nil(request.faction), do: raise(ArgumentError, "required field faction is nil")
    if is_nil(request.symbol), do: raise(ArgumentError, "required field symbol is nil")

    %{}
    |> then(fn json ->
      if is_nil(request.email), do: json, else: Map.put(json, "email", request.email)
    end)
    |> Map.put("faction", request.faction)
    |> Map.put("symbol", request.symbol)
  end
end
