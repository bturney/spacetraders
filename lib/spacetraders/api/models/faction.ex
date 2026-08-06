defmodule SpaceTraders.API.Model.Faction do
  @moduledoc "Faction details."

  defstruct [
    :description,
    :headquarters,
    :is_recruiting,
    :name,
    :symbol,
    :traits
  ]

  @type t :: %__MODULE__{
          description: String.t(),
          headquarters: String.t() | nil,
          is_recruiting: boolean(),
          name: String.t(),
          symbol: String.t(),
          traits: [SpaceTraders.API.Model.FactionTrait.t()]
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Faction`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      description: json["description"],
      headquarters: json["headquarters"],
      is_recruiting: json["isRecruiting"],
      name: json["name"],
      symbol: json["symbol"],
      traits: Enum.map(json["traits"] || [], &SpaceTraders.API.Model.FactionTrait.from_json/1)
    }
  end
end
