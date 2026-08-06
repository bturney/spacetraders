defmodule SpaceTraders.API.Model.ScannedShipEngine do
  @moduledoc "The engine of the ship."

  defstruct [
    :symbol
  ]

  @type t :: %__MODULE__{
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScannedShipEngine`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"]
    }
  end
end
