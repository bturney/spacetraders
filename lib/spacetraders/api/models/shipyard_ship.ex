defmodule SpaceTraders.API.Model.ShipyardShip do
  @moduledoc ""

  defstruct [
    :activity,
    :crew,
    :description,
    :engine,
    :frame,
    :modules,
    :mounts,
    :name,
    :purchase_price,
    :reactor,
    :supply,
    :type
  ]

  @type t :: %__MODULE__{
          activity: String.t() | nil,
          crew: SpaceTraders.API.Model.ShipyardShipCrew.t(),
          description: String.t(),
          engine: SpaceTraders.API.Model.ShipEngine.t(),
          frame: SpaceTraders.API.Model.ShipFrame.t(),
          modules: [SpaceTraders.API.Model.ShipModule.t()],
          mounts: [SpaceTraders.API.Model.ShipMount.t()],
          name: String.t(),
          purchase_price: integer(),
          reactor: SpaceTraders.API.Model.ShipReactor.t(),
          supply: String.t(),
          type: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ShipyardShip`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      activity: json["activity"],
      crew: json["crew"] && SpaceTraders.API.Model.ShipyardShipCrew.from_json(json["crew"]),
      description: json["description"],
      engine: json["engine"] && SpaceTraders.API.Model.ShipEngine.from_json(json["engine"]),
      frame: json["frame"] && SpaceTraders.API.Model.ShipFrame.from_json(json["frame"]),
      modules: Enum.map(json["modules"] || [], &SpaceTraders.API.Model.ShipModule.from_json/1),
      mounts: Enum.map(json["mounts"] || [], &SpaceTraders.API.Model.ShipMount.from_json/1),
      name: json["name"],
      purchase_price: json["purchasePrice"],
      reactor: json["reactor"] && SpaceTraders.API.Model.ShipReactor.from_json(json["reactor"]),
      supply: json["supply"],
      type: json["type"]
    }
  end
end
