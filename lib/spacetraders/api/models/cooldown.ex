defmodule SpaceTraders.API.Model.Cooldown do
  @moduledoc "A cooldown is a period of time in which a ship cannot perform certain actions."

  defstruct [
    :expiration,
    :remaining_seconds,
    :ship_symbol,
    :total_seconds
  ]

  @type t :: %__MODULE__{
          expiration: String.t() | nil,
          remaining_seconds: integer(),
          ship_symbol: String.t(),
          total_seconds: integer()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Cooldown`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      expiration: json["expiration"],
      remaining_seconds: json["remainingSeconds"],
      ship_symbol: json["shipSymbol"],
      total_seconds: json["totalSeconds"]
    }
  end
end
