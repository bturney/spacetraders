defmodule SpaceTraders.CreditCalibration.Realization do
  @moduledoc "Realized-versus-quoted evidence for one attributable credit-bearing attempt."

  use Ecto.Schema

  schema "credit_realizations" do
    field :operation_id, :string
    field :unit_price, :integer
    field :units, :integer
    field :worst_case_exposure, :integer
    field :realized_charge, :integer
    field :credits_after, :integer
    field :within_bound, :boolean

    belongs_to :agent, SpaceTraders.Agent.Agent
    belongs_to :mutation_attempt, SpaceTraders.MutationAttempts.Attempt, type: :binary_id
    belongs_to :calibration_version, SpaceTraders.CreditCalibration.Version
    belongs_to :credit_shortfall, SpaceTraders.CreditCalibration.Shortfall

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
