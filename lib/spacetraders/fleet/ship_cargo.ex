defmodule SpaceTraders.Fleet.ShipCargo do
  @moduledoc "One Trade Good a Ship holds as Cargo, replaced as a set on each observation."

  use Ecto.Schema

  schema "ship_cargo" do
    field :trade_symbol, :string
    field :units, :integer

    belongs_to :ship, SpaceTraders.Fleet.Ship
  end
end
