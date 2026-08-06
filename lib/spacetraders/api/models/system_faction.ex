defmodule SpaceTraders.API.Model.SystemFaction do
  @moduledoc ""

  defstruct [
    :symbol
  ]

  @type t :: %__MODULE__{
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.SystemFaction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      symbol: json["symbol"]
    }
  end
end
