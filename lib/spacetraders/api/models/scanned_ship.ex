defmodule SpaceTraders.API.Model.ScannedShip do
  @moduledoc "The ship that was scanned. Details include information about the ship that could be detected by the scanner."

  defstruct [
    :engine,
    :frame,
    :mounts,
    :nav,
    :reactor,
    :registration,
    :symbol
  ]

  @type t :: %__MODULE__{
          engine: SpaceTraders.API.Model.ScannedShipEngine.t(),
          frame: SpaceTraders.API.Model.ScannedShipFrame.t() | nil,
          mounts: [SpaceTraders.API.Model.ScannedShipMounts.t()] | nil,
          nav: SpaceTraders.API.Model.ShipNav.t(),
          reactor: SpaceTraders.API.Model.ScannedShipReactor.t() | nil,
          registration: SpaceTraders.API.Model.ShipRegistration.t(),
          symbol: String.t()
        }

  @doc "Decodes an API payload map into `SpaceTraders.API.Model.ScannedShip`."
  @spec from_json(map()) :: t()
  def from_json(json) when is_map(json) do
    %__MODULE__{
      engine:
        json["engine"] && SpaceTraders.API.Model.ScannedShipEngine.from_json(json["engine"]),
      frame: json["frame"] && SpaceTraders.API.Model.ScannedShipFrame.from_json(json["frame"]),
      mounts:
        Enum.map(json["mounts"] || [], &SpaceTraders.API.Model.ScannedShipMounts.from_json/1),
      nav: json["nav"] && SpaceTraders.API.Model.ShipNav.from_json(json["nav"]),
      reactor:
        json["reactor"] && SpaceTraders.API.Model.ScannedShipReactor.from_json(json["reactor"]),
      registration:
        json["registration"] &&
          SpaceTraders.API.Model.ShipRegistration.from_json(json["registration"]),
      symbol: json["symbol"]
    }
  end
end
