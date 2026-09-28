defmodule SpaceTraders.OperatorConditions.Condition do
  @moduledoc "Durable Operator-facing Attention or Intervention, separate from acknowledgement."

  use Ecto.Schema
  import Ecto.Changeset

  schema "mission_conditions" do
    field :key, :string
    field :kind, Ecto.Enum, values: [:attention, :intervention]
    field :summary, :string
    field :entity_ref, :string
    field :acknowledged_at, :utc_datetime_usec
    field :resolved_at, :utc_datetime_usec

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :fleet_generation, SpaceTraders.FleetGeneration.Generation
    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision

    belongs_to :strategy_decision_episode,
               SpaceTraders.FleetAllocation.StrategyDecisionEpisode

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(condition, attrs) do
    condition
    |> cast(attrs, [
      :operator_id,
      :key,
      :kind,
      :summary,
      :entity_ref,
      :fleet_generation_id,
      :fleet_strategy_revision_id,
      :strategy_decision_episode_id,
      :acknowledged_at,
      :resolved_at
    ])
    |> validate_required([:operator_id, :key, :kind, :summary])
    |> unique_constraint([:operator_id, :key], name: :mission_conditions_unresolved_key_index)
  end
end
