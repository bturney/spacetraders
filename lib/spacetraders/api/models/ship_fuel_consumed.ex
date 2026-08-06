defmodule SpaceTraders.API.Model.ShipFuelConsumed do
  @moduledoc "An object that only shows up when an action has consumed fuel in the process. Shows the fuel consumption data."

  defstruct [
    :amount,
    :timestamp
  ]

  @type t :: %__MODULE__{
          amount: integer(),
          timestamp: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipFuelConsumed`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      amount: json["amount"],
      timestamp: json["timestamp"]
    }
  end
end
