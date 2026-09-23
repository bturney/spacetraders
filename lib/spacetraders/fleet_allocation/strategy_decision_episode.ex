defmodule SpaceTraders.FleetAllocation.StrategyDecisionEpisode do
  @moduledoc false

  use Ecto.Schema

  schema "strategy_decision_episodes" do
    field :source_version, :integer
    field :evidence_references, {:array, :map}, default: []
    field :alternatives, {:array, :map}, default: []
    field :binding_constraints, {:array, :map}, default: []
    field :expectations, :map, default: %{}
    field :actual_outcomes, :map, default: %{}
    field :calibration_version, :string

    field :classification, Ecto.Enum,
      values: [:still_evaluating, :realized, :partially_realized, :superseded, :reset_censored],
      default: :still_evaluating

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :fleet_generation, SpaceTraders.FleetGeneration.Generation
    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision

    timestamps(type: :utc_datetime_usec)
  end
end
