defmodule SpaceTraders.Fleet.Activity do
  @moduledoc "Append-only local Fleet activity for Operator-visible recovery and progress."

  use Ecto.Schema

  schema "fleet_activity" do
    field :kind, :string
    field :message, :string
    field :metadata, :map, default: %{}

    belongs_to :agent, SpaceTraders.Agent.Agent
    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end
end
