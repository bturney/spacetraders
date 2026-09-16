defmodule SpaceTraders.MutationAttempts.Outcome do
  @moduledoc false

  use Ecto.Schema

  schema "mutation_attempt_outcomes" do
    field :classification, :string
    field :evidence, :map
    field :recorded_at, :utc_datetime_usec

    belongs_to :mutation_attempt, SpaceTraders.MutationAttempts.Attempt, type: :binary_id

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end
