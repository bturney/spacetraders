defmodule SpaceTraders.API.Model.Shipyard do
  @moduledoc "Shipyard details."

  defstruct [
    :modifications_fee,
    :ship_types,
    :ships,
    :symbol,
    :transactions
  ]

  @type t :: %__MODULE__{
          modifications_fee: integer(),
          ship_types: [SpaceTraders.API.Model.ShipyardShipTypes.t()],
          ships: [SpaceTraders.API.Model.ShipyardShip.t()] | nil,
          symbol: String.t(),
          transactions: [SpaceTraders.API.Model.ShipyardTransaction.t()] | nil
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Shipyard`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      modifications_fee: json["modificationsFee"],
      ship_types:
        Enum.map(json["shipTypes"] || [], &SpaceTraders.API.Model.ShipyardShipTypes.from_json/1),
      ships: Enum.map(json["ships"] || [], &SpaceTraders.API.Model.ShipyardShip.from_json/1),
      symbol: json["symbol"],
      transactions:
        Enum.map(
          json["transactions"] || [],
          &SpaceTraders.API.Model.ShipyardTransaction.from_json/1
        )
    }
  end
end
