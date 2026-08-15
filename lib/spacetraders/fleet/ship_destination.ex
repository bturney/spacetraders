defmodule SpaceTraders.Fleet.ShipDestination do
  @moduledoc "A recent successful navigation destination owned by a Ship."

  use Ecto.Schema

  schema "ship_destination_history" do
    field :waypoint_symbol, :string
    field :position, :integer

    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end
end
