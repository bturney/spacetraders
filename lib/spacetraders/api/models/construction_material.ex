defmodule SpaceTraders.API.Model.ConstructionMaterial do
  @moduledoc "The details of the required construction materials for a given waypoint under construction."

  defstruct [
    :fulfilled,
    :required,
    :trade_symbol
  ]

  @type t :: %__MODULE__{
          fulfilled: integer(),
          required: integer(),
          trade_symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ConstructionMaterial`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      fulfilled: json["fulfilled"],
      required: json["required"],
      trade_symbol: json["tradeSymbol"]
    }
  end
end
