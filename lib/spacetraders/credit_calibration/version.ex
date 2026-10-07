defmodule SpaceTraders.CreditCalibration.Version do
  @moduledoc "One immutable worst-case margin version; the newest row is active."

  use Ecto.Schema
  import Ecto.Changeset

  @hard_lower_bound 10

  schema "credit_calibration_versions" do
    field :version, :string
    field :margin_percent, :integer
    field :basis, :string
    field :evidence, :map, default: %{}

    belongs_to :previous_version, __MODULE__
    belongs_to :mutation_attempt, SpaceTraders.MutationAttempts.Attempt, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def hard_lower_bound, do: @hard_lower_bound

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :version,
      :margin_percent,
      :basis,
      :evidence,
      :previous_version_id,
      :mutation_attempt_id
    ])
    |> validate_required([:version, :margin_percent, :basis, :previous_version_id])
    |> validate_number(:margin_percent, greater_than_or_equal_to: @hard_lower_bound)
    |> check_constraint(:margin_percent, name: :credit_calibration_hard_lower_bound)
    |> unique_constraint(:version)
  end
end
