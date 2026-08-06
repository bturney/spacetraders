defmodule SpaceTraders.API.Model.ShipConditionEvent do
  @moduledoc "An event that represents damage or wear to a ship's reactor, frame, or engine, reducing the condition of the ship."

  defstruct [
    :component,
    :description,
    :name,
    :symbol
  ]

  @type t :: %__MODULE__{
          component: String.t(),
          description: String.t(),
          name: String.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipConditionEvent`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      component: json["component"],
      description: json["description"],
      name: json["name"],
      symbol: json["symbol"]
    }
  end
end
