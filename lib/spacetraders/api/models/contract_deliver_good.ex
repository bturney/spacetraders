defmodule SpaceTraders.API.Model.ContractDeliverGood do
  @moduledoc "The details of a delivery contract. Includes the type of good, units needed, and the destination."

  defstruct [
    :destination_symbol,
    :trade_symbol,
    :units_fulfilled,
    :units_required
  ]

  @type t :: %__MODULE__{
          destination_symbol: String.t(),
          trade_symbol: String.t(),
          units_fulfilled: integer(),
          units_required: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ContractDeliverGood`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      destination_symbol: json["destinationSymbol"],
      trade_symbol: json["tradeSymbol"],
      units_fulfilled: json["unitsFulfilled"],
      units_required: json["unitsRequired"]
    }
  end
end
