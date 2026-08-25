defmodule SpaceTraders.Fleet.Job do
  @moduledoc "A durable, operator-selected outcome for one Ship."

  use Ecto.Schema
  import Ecto.Changeset

  @unfinished_states ["active", "waiting", "blocked", "paused"]
  @terminal_states ["completed", "failed", "stopped", "replaced"]
  @running_states ["active", "waiting"]

  schema "jobs" do
    field :type, :string, default: "miner"
    field :gather_mode, :string, default: "extract"
    field :extraction_waypoint, :string
    field :market_waypoint, :string
    field :cargo_threshold, :integer
    # Retained for deployed rows; Job State is the sole runtime lifecycle.
    field :desired_mode, :string, default: "manual"
    field :status, :string, default: "paused"
    field :blocked_reason, :string
    field :blocker, :map
    field :last_validated_at, :utc_datetime
    field :in_flight_action, :map
    field :last_action_result, :map
    field :progress, :map, default: %{}
    field :recovery_attempts, :integer, default: 0
    field :sellable_goods, {:array, :string}, default: []
    field :contract_deliverables, {:array, :map}, default: []
    field :finished_at, :utc_datetime

    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end

  def unfinished_states, do: @unfinished_states
  def terminal_states, do: @terminal_states
  def running_states, do: @running_states
  def running?(%__MODULE__{status: status}), do: status in @running_states
  def running?(_job), do: false

  def changeset(job, attrs) do
    job
    |> cast(attrs, [
      :type,
      :gather_mode,
      :extraction_waypoint,
      :market_waypoint,
      :cargo_threshold,
      :status,
      :blocked_reason,
      :blocker,
      :last_validated_at
    ])
    |> validate_required([:type, :extraction_waypoint, :market_waypoint, :cargo_threshold])
    |> validate_inclusion(:type, ["miner"])
    |> validate_inclusion(:gather_mode, ["extract", "siphon"])
    |> validate_number(:cargo_threshold, greater_than: 0)
    |> validate_inclusion(:status, @unfinished_states ++ @terminal_states)
    |> unique_constraint(:ship_id, name: :jobs_one_unfinished_per_ship_index)
  end
end
