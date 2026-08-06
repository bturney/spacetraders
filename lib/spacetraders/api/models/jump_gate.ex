defmodule SpaceTraders.API.Model.JumpGate do
  @moduledoc ""

  defstruct [
    :connections,
    :symbol
  ]

  @type t :: %__MODULE__{
          connections: [String.t()],
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.JumpGate`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      connections: json["connections"] || [],
      symbol: json["symbol"]
    }
  end
end
