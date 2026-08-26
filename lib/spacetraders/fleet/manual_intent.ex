defmodule SpaceTraders.Fleet.ManualIntent do
  @moduledoc """
  A durable Manual Control Intent for one Ship.

  Manual Control is an alternate caller of a reusable outcome-level Intent, not
  a Job or durable Ship mode (ADR context: Phase 3.5 single-Ship outcomes). The
  active intent chain, meaningful progress, and in-flight request/response
  evidence persist across restarts so recovery can reconcile game truth before
  another mutation instead of blindly replaying a command.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @unfinished_states ["active", "waiting", "blocked"]
  @terminal_states ["completed", "stopped"]

  schema "manual_intents" do
    field :type, :string, default: "navigate"
    field :target_waypoint, :string
    field :status, :string, default: "active"
    field :blocked_reason, :string
    embeds_one :blocker, SpaceTraders.Fleet.JobBlocker
    field :in_flight_action, :map
    field :last_action_result, :map
    field :recovery_attempts, :integer, default: 0
    field :finished_at, :utc_datetime

    belongs_to :ship, SpaceTraders.Fleet.Ship

    timestamps(type: :utc_datetime)
  end

  def unfinished_states, do: @unfinished_states
  def terminal_states, do: @terminal_states

  def unfinished?(%__MODULE__{status: status}), do: status in @unfinished_states
  def unfinished?(_intent), do: false

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [:type, :target_waypoint, :status])
    |> cast_embed(:blocker)
    |> validate_required([:type, :target_waypoint])
    |> validate_inclusion(:type, ["navigate"])
    |> validate_inclusion(:status, @unfinished_states ++ @terminal_states)
  end
end
