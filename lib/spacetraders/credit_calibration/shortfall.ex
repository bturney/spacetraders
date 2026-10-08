defmodule SpaceTraders.CreditCalibration.Shortfall do
  @moduledoc """
  A durable below-floor or above-bound credit condition. While unreleased it
  pauses new credit-bearing admission for its Agent. Only `pricing_model_miss`
  is attributed to one attempt's bound and widens calibration.
  """

  use Ecto.Schema

  @kinds ~w(pricing_model_miss unattributable_shortfall revision_floor non_pricing_shortfall)

  schema "credit_shortfalls" do
    field :kind, :string
    field :credits, :integer
    field :credit_floor, :integer
    field :worst_case_exposure, :integer
    field :realized_charge, :integer
    field :evidence, :map, default: %{}
    field :detected_at, :utc_datetime_usec
    field :released_at, :utc_datetime_usec
    field :release_evidence, :map

    belongs_to :agent, SpaceTraders.Agent.Agent
    belongs_to :mutation_attempt, SpaceTraders.MutationAttempts.Attempt, type: :binary_id
    belongs_to :calibration_version, SpaceTraders.CreditCalibration.Version
    belongs_to :widened_calibration_version, SpaceTraders.CreditCalibration.Version
    belongs_to :strategy_revision, SpaceTraders.FleetStrategy.Revision

    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
end
