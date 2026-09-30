defmodule SpaceTraders.FleetAllocation.AllocationResultPointer do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:fleet_generation_id, :integer, autogenerate: false}

  schema "allocation_result_pointers" do
    field :selection_kind, Ecto.Enum,
      values: SpaceTraders.FleetAllocation.StrategyDecisionEpisode.selection_kinds()

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision
    belongs_to :strategy_decision_episode, SpaceTraders.FleetAllocation.StrategyDecisionEpisode

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
