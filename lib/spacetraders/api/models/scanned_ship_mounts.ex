defmodule SpaceTraders.API.Model.ScannedShipMounts do
  @moduledoc "A mount on the ship."

  defstruct [
    :symbol
  ]

  @type t :: %__MODULE__{
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScannedShipMounts`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"]
    }
  end
end
