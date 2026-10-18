defmodule SpaceTraders.Fleet.Ship do
  @moduledoc """
  A ship owned by an Agent, with its last observed current state.

  Registration establishes the row; `SpaceTraders.Fleet.record_ship_state/3`
  then keeps spec, nav, fuel, the one current route and Cargo as the game last
  reported them, so read surfaces never call the game.
  """

  use Ecto.Schema

  schema "ships" do
    field :symbol, :string
    field :ship_type, :string
    # Set when its Agent's Fleet Generation is replaced: retained as history,
    # never a resource of the replacement, even when it reuses the symbol.
    field :retired_at, :utc_datetime

    # Spec
    field :engine_speed, :integer
    field :engine_condition, :float
    field :fuel_capacity, :integer
    field :cargo_capacity, :integer

    # Current state, as of `state_observed_at`
    field :nav_status, :string
    field :waypoint_symbol, :string
    field :fuel_current, :integer
    field :state_observed_at, :utc_datetime_usec

    # The one current route; arrival in the past means the Ship has arrived.
    field :route_origin, :string
    field :route_destination, :string
    field :route_departed_at, :utc_datetime
    field :route_arrives_at, :utc_datetime

    belongs_to :agent, SpaceTraders.Agent.Agent
    has_many :intents, SpaceTraders.Fleet.Intent
    has_many :destination_history, SpaceTraders.Fleet.ShipDestination
    has_many :cargo, SpaceTraders.Fleet.ShipCargo, preload_order: [asc: :trade_symbol]

    timestamps(type: :utc_datetime)
  end
end
