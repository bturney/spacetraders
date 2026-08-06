defmodule SpaceTraders.API.Model.Contract do
  @moduledoc "Contract details."

  defstruct [
    :accepted,
    :deadline_to_accept,
    :expiration,
    :faction_symbol,
    :fulfilled,
    :id,
    :terms,
    :type
  ]

  @type t :: %__MODULE__{
          accepted: boolean(),
          deadline_to_accept: String.t() | nil,
          expiration: String.t(),
          faction_symbol: String.t(),
          fulfilled: boolean(),
          id: String.t(),
          terms: SpaceTraders.API.Model.ContractTerms.t(),
          type: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Contract`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      accepted: json["accepted"],
      deadline_to_accept: json["deadlineToAccept"],
      expiration: json["expiration"],
      faction_symbol: json["factionSymbol"],
      fulfilled: json["fulfilled"],
      id: json["id"],
      terms: json["terms"] && SpaceTraders.API.Model.ContractTerms.from_json(json["terms"]),
      type: json["type"]
    }
  end
end
