defmodule SpaceTraders.Fleet.AutopilotConfig do
  @moduledoc "Durable, operator-owned configuration and status for one Ship's Autopilot."

  use Ecto.Schema
  import Ecto.Changeset

  schema "autopilot_configs" do
    field :extraction_waypoint, :string
    field :market_waypoint, :string
    field :cargo_threshold, :integer
    field :desired_mode, :string, default: "manual"
    field :status, :string, default: "ready"
    field :blocked_reason, :string
    field :last_validated_at, :utc_datetime

    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :extraction_waypoint,
      :market_waypoint,
      :cargo_threshold,
      :desired_mode,
      :status,
      :blocked_reason,
      :last_validated_at
    ])
    |> validate_required([:extraction_waypoint, :market_waypoint, :cargo_threshold])
    |> validate_number(:cargo_threshold, greater_than: 0)
    |> validate_inclusion(:desired_mode, ["manual", "autopilot"])
    |> validate_inclusion(:status, ["revalidating", "ready", "waiting", "blocked", "paused"])
    |> unique_constraint(:ship_id)
  end
end
