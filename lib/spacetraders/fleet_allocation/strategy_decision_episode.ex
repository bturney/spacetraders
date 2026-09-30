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

    # The admissible alternatives this episode considered and did not select.
    # A selected plan records the rejected candidates; a Neutral Wait records
    # one tagged candidate bundle, since nothing was admissible to reject
    # against a chosen portfolio.
    field :alternatives, {:array, :map}, default: []

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

  @doc """
  The tag identifying the single candidate bundle a Neutral Wait retained.

  Selected-plan episodes carry rejected candidates instead, so the tag is what
  distinguishes "nothing was admissible" from "these were not selected".
  """
  def neutral_wait_bundle, do: "neutral_wait_candidates"
end
