defmodule SpaceTraders.Api.Types.ShipEngine do
  @type t :: %__MODULE__{
    symbol: String.t(),
    name: String.t(),
    description: String.t(),
    condition: SpaceTraders.Api.Types.ShipComponentCondition.t() | nil,
    integrity: SpaceTraders.Api.Types.ShipComponentIntegrity.t() | nil,
    speed: integer(),
    requirements: SpaceTraders.Api.Types.ShipRequirements.t() | nil,
    quality: SpaceTraders.Api.Types.ShipComponentQuality.t() | nil
  }

  defstruct [
    :symbol,
    :name,
    :description,
    :condition,
    :integrity,
    :speed,
    :requirements,
    :quality
  ]
end
