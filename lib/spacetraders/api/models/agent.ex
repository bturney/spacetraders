defmodule SpaceTraders.API.Model.Agent do
  @moduledoc "Agent details."

  defstruct [
    :account_id,
    :credits,
    :headquarters,
    :ship_count,
    :starting_faction,
    :symbol
  ]

  @type t :: %__MODULE__{
          account_id: String.t() | nil,
          credits: integer(),
          headquarters: String.t(),
          ship_count: integer(),
          starting_faction: String.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Agent`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      account_id: json["accountId"],
      credits: json["credits"],
      headquarters: json["headquarters"],
      ship_count: json["shipCount"],
      starting_faction: json["startingFaction"],
      symbol: json["symbol"]
    }
  end
end
