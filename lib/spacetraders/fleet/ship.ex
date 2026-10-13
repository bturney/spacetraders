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
    # Set when its Agent's Fleet Generation is replaced: retained as history,
    # never a resource of the replacement, even when it reuses the symbol.
    field :retired_at, :utc_datetime

    belongs_to :agent, SpaceTraders.Agent.Agent
    has_many :intents, SpaceTraders.Fleet.Intent
    has_many :destination_history, SpaceTraders.Fleet.ShipDestination

    timestamps(type: :utc_datetime)
  end
end
