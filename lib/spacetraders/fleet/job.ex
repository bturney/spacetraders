defmodule SpaceTraders.Fleet.Job do
  @moduledoc "A durable, operator-selected outcome for one Ship."

  use Ecto.Schema
  import Ecto.Changeset

  schema "jobs" do
    field :type, :string, default: "miner"
    field :extraction_waypoint, :string
    field :market_waypoint, :string
    field :cargo_threshold, :integer
    field :desired_mode, :string, default: "manual"
    field :status, :string, default: "ready"
    field :blocked_reason, :string
    field :last_validated_at, :utc_datetime
    field :in_flight_action, :map
    field :last_action_result, :map
    field :progress, :map, default: %{}
    field :recovery_attempts, :integer, default: 0
    field :sellable_goods, {:array, :string}, default: []

    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :type,
      :extraction_waypoint,
      :market_waypoint,
      :cargo_threshold,
      :desired_mode,
      :status,
      :blocked_reason,
      :last_validated_at
    ])
    |> validate_required([:type, :extraction_waypoint, :market_waypoint, :cargo_threshold])
    |> validate_inclusion(:type, ["miner"])
    |> validate_number(:cargo_threshold, greater_than: 0)
    |> validate_inclusion(:desired_mode, ["manual", "active"])
    |> validate_inclusion(:status, ["revalidating", "ready", "waiting", "blocked", "paused"])
    |> unique_constraint(:ship_id)
  end
end
