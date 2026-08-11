defmodule SpaceTraders.Fleet.Ship do
  @moduledoc """
  A ship owned by an Agent, cached locally.

  Minimal schema seeded with the starter fleet; the Fleet context (owned fleet
  actions, fuel/cargo/cooldown state) arrives in the fleet command panel ticket.
  """

  use Ecto.Schema

  schema "ships" do
    field :symbol, :string
    field :ship_type, :string

    belongs_to :agent, SpaceTraders.Agent.Agent
    has_one :autopilot_config, SpaceTraders.Fleet.AutopilotConfig

    timestamps(type: :utc_datetime)
  end
end
