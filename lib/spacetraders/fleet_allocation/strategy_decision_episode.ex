defmodule SpaceTraders.FleetAllocation.JsonDocument do
  @moduledoc false

  use Ecto.Type

  # Selected-plan episodes retain the rejected alternatives list; Neutral Wait
  # episodes retain one candidate-bundle map. Both are JSON documents in the
  # same jsonb column, so the type passes either shape through untouched.
  def type, do: :map

  def cast(value) when is_map(value) or is_list(value), do: {:ok, value}
  def cast(_value), do: :error

  def load(value) when is_map(value) or is_list(value), do: {:ok, value}
  def load(_value), do: :error

  def dump(value) when is_map(value) or is_list(value), do: {:ok, value}
  def dump(_value), do: :error
end

defmodule SpaceTraders.FleetAllocation.StrategyDecisionEpisode do
  @moduledoc false

  use Ecto.Schema

  @selection_kinds [:selected_plan, :neutral_wait]

  @limitation_kinds [
    :incomplete_coverage,
    :no_admissible_candidate,
    :below_economic_threshold,
    :awaiting_scheduled_evidence
  ]

  schema "strategy_decision_episodes" do
    field :source_version, :integer
    field :evidence_references, {:array, :map}, default: []
    # Selected-plan episodes retain the rejected alternatives list; Neutral
    # Wait episodes retain one candidate-bundle map (candidates, rejection
    # reasons, reconciled subjects). Both are JSON documents.
    field :alternatives, SpaceTraders.FleetAllocation.JsonDocument, default: []
    field :binding_constraints, {:array, :map}, default: []
    field :expectations, :map, default: %{}
    field :actual_outcomes, :map, default: %{}
    field :calibration_version, :string

    field :selection_kind, Ecto.Enum, values: @selection_kinds, default: :selected_plan

    field :binding_limitation_kind, Ecto.Enum, values: @limitation_kinds

    field :next_observation_at, :utc_datetime_usec

    field :classification, Ecto.Enum,
      values: [:still_evaluating, :realized, :partially_realized, :superseded, :reset_censored],
      default: :still_evaluating

    belongs_to :operator, SpaceTraders.Agent.Operator
    belongs_to :fleet_generation, SpaceTraders.FleetGeneration.Generation
    belongs_to :fleet_strategy_revision, SpaceTraders.FleetStrategy.Revision

    timestamps(type: :utc_datetime_usec)
  end

  @doc "The durable selection kinds fixed by ADR 0012."
  def selection_kinds, do: @selection_kinds

  @doc "The closed limitation-kind vocabulary used by wait metrics and labels."
  def limitation_kinds, do: @limitation_kinds
end
