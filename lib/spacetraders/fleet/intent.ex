defmodule SpaceTraders.Fleet.Intent do
  @moduledoc """
  A durable cargo-operation Intent for one Ship.

  Manual Control and Job policies are callers of a reusable outcome-level
  Intent, not a durable Ship mode (Phase 3.5 single-Ship outcomes). The active
  intent chain, meaningful progress, and in-flight request/response evidence
  persist across restarts so recovery can reconcile game truth before another
  mutation instead of blindly replaying a command.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @unfinished_states ["active", "waiting", "awaiting_confirmation", "blocked"]
  @terminal_states ["completed", "stopped"]

  schema "intents" do
    # "manual" intents belong to Manual Control; "job" intents are the
    # operation ledger for a Job policy and never preempt their owning Job.
    field :caller, :string, default: "manual"
    field :type, :string, default: "navigate"
    field :target_waypoint, :string
    # Operation-specific target, quantity, price, and recipient constraints.
    field :parameters, :map, default: %{}
    field :review_revision, :integer, default: 0
    field :status, :string, default: "active"
    embeds_one :blocker, SpaceTraders.Fleet.JobBlocker
    field :in_flight_action, :map
    field :last_action_result, :map
    field :recovery_attempts, :integer, default: 0
    field :finished_at, :utc_datetime

    belongs_to :ship, SpaceTraders.Fleet.Ship
    belongs_to :job, SpaceTraders.Fleet.Job

    timestamps(type: :utc_datetime)
  end

  def unfinished_states, do: @unfinished_states
  def terminal_states, do: @terminal_states

  def unfinished?(%__MODULE__{status: status}), do: status in @unfinished_states
  def unfinished?(_intent), do: false

  def changeset(intent, attrs) do
    intent
    |> cast(attrs, [
      :caller,
      :type,
      :target_waypoint,
      :parameters,
      :review_revision,
      :status,
      :job_id
    ])
    |> cast_embed(:blocker)
    |> validate_required([:caller, :type, :target_waypoint])
    |> validate_inclusion(:caller, ["manual", "job"])
    |> validate_job_owner()
    |> validate_inclusion(:type, [
      "navigate",
      "buy",
      "sell",
      "deliver",
      "install_module",
      "remove_module"
    ])
    |> validate_inclusion(:status, @unfinished_states ++ @terminal_states)
    |> unique_constraint(:ship_id, name: :intents_one_active_per_ship_index)
  end

  defp validate_job_owner(%Ecto.Changeset{changes: %{caller: "job"}} = changeset),
    do: validate_required(changeset, [:job_id])

  defp validate_job_owner(%Ecto.Changeset{data: %{caller: "job"}} = changeset),
    do: validate_required(changeset, [:job_id])

  defp validate_job_owner(changeset), do: changeset
end
