defmodule SpaceTraders.API.Model.ShipyardShipTypes do
  @moduledoc ""

  defstruct [
    :type
  ]

  @type t :: %__MODULE__{
          type: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipyardShipTypes`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      type: json["type"]
    }
  end
end
