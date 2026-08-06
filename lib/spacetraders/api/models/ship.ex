defmodule SpaceTraders.API.Model.Ship do
  @moduledoc "Ship details."

  defstruct [
    :cargo,
    :cooldown,
    :crew,
    :engine,
    :frame,
    :fuel,
    :modules,
    :mounts,
    :nav,
    :reactor,
    :registration,
    :symbol
  ]

  @type t :: %__MODULE__{
          cargo: SpaceTraders.API.Model.ShipCargo.t(),
          cooldown: SpaceTraders.API.Model.Cooldown.t(),
          crew: SpaceTraders.API.Model.ShipCrew.t(),
          engine: SpaceTraders.API.Model.ShipEngine.t(),
          frame: SpaceTraders.API.Model.ShipFrame.t(),
          fuel: SpaceTraders.API.Model.ShipFuel.t(),
          modules: [SpaceTraders.API.Model.ShipModule.t()],
          mounts: [SpaceTraders.API.Model.ShipMount.t()],
          nav: SpaceTraders.API.Model.ShipNav.t(),
          reactor: SpaceTraders.API.Model.ShipReactor.t(),
          registration: SpaceTraders.API.Model.ShipRegistration.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.Ship`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      cargo: json["cargo"] && SpaceTraders.API.Model.ShipCargo.from_json(json["cargo"]),
      cooldown: json["cooldown"] && SpaceTraders.API.Model.Cooldown.from_json(json["cooldown"]),
      crew: json["crew"] && SpaceTraders.API.Model.ShipCrew.from_json(json["crew"]),
      engine: json["engine"] && SpaceTraders.API.Model.ShipEngine.from_json(json["engine"]),
      frame: json["frame"] && SpaceTraders.API.Model.ShipFrame.from_json(json["frame"]),
      fuel: json["fuel"] && SpaceTraders.API.Model.ShipFuel.from_json(json["fuel"]),
      modules: Enum.map(json["modules"] || [], &SpaceTraders.API.Model.ShipModule.from_json/1),
      mounts: Enum.map(json["mounts"] || [], &SpaceTraders.API.Model.ShipMount.from_json/1),
      nav: json["nav"] && SpaceTraders.API.Model.ShipNav.from_json(json["nav"]),
      reactor: json["reactor"] && SpaceTraders.API.Model.ShipReactor.from_json(json["reactor"]),
      registration:
        json["registration"] &&
          SpaceTraders.API.Model.ShipRegistration.from_json(json["registration"]),
      symbol: json["symbol"]
    }
  end
end
