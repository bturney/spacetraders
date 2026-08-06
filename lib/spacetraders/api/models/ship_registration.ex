defmodule SpaceTraders.API.Model.ShipRegistration do
  @moduledoc "The public registration information of the ship"

  defstruct [
    :faction_symbol,
    :name,
    :role
  ]

  @type t :: %__MODULE__{
          faction_symbol: String.t(),
          name: String.t(),
          role: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipRegistration`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      faction_symbol: json["factionSymbol"],
      name: json["name"],
      role: json["role"]
    }
  end
end
