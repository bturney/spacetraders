defmodule SpaceTraders.Fleet.Intent do
  @moduledoc """
  A durable cargo-operation Intent for one Ship.

  Fleet Commitment and Manual Intervention callers use a reusable outcome-level
  Intent, not a durable Ship mode. The active intent chain, meaningful progress,
  and in-flight request/response evidence persist across restarts so recovery
  can reconcile game truth before another mutation instead of blindly replaying
  a command.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @unfinished_states ["active", "waiting", "awaiting_confirmation", "blocked"]
  @terminal_states ["completed", "infeasible", "stopped", "superseded"]

  schema "intents" do
    # Fleet Commitment and authenticated intervention Intents are scoped by the
    # Fleet Commitment authorization layer before execution.
    field :caller, :string
    field :type, :string, default: "navigate"
    field :target_waypoint, :string
    # Operation-specific target, quantity, price, and recipient constraints.
    field :parameters, :map, default: %{}
    field :review_revision, :integer, default: 0
    field :status, :string, default: "active"
    embeds_one :blocker, SpaceTraders.Fleet.IntentBlocker, on_replace: :delete
    field :in_flight_action, :map
    field :last_action_result, :map
    field :recovery_attempts, :integer, default: 0
    field :finished_at, :utc_datetime
    field :fleet_commitment_portfolio_version, :integer

    belongs_to :ship, SpaceTraders.Fleet.Ship
    belongs_to :fleet_commitment, SpaceTraders.FleetAllocation.Commitment

    belongs_to :fleet_commitment_portfolio, SpaceTraders.FleetAllocation.Portfolio

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
      :fleet_commitment_id,
      :fleet_commitment_portfolio_id,
      :fleet_commitment_portfolio_version
    ])
    |> cast_embed(:blocker)
    |> validate_required([:caller, :type, :target_waypoint])
    |> validate_inclusion(:caller, ["commitment", "intervention"])
    |> validate_commitment_owner()
    |> validate_inclusion(:type, [
      "navigate",
      "acquire_intelligence",
      "acquire_resources",
      "buy",
      "sell",
      "deliver",
      "install_module",
      "remove_module"
    ])
    |> validate_inclusion(:status, @unfinished_states ++ @terminal_states)
    |> unique_constraint(:ship_id, name: :intents_one_active_per_ship_index)
  end

  defp validate_commitment_owner(%Ecto.Changeset{changes: %{caller: "commitment"}} = changeset),
    do: validate_required(changeset, [:fleet_commitment_id, :fleet_commitment_portfolio_id])

  defp validate_commitment_owner(%Ecto.Changeset{data: %{caller: "commitment"}} = changeset),
    do: validate_required(changeset, [:fleet_commitment_id, :fleet_commitment_portfolio_id])

  defp validate_commitment_owner(changeset), do: changeset
end
