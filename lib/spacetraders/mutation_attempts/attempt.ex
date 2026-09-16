defmodule SpaceTraders.MutationAttempts.Attempt do
  @moduledoc false

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "mutation_attempts" do
    field :operation_id, :string
    field :operation_owner, :string
    field :state, :string
    field :request_fingerprint, :string
    field :prepared_evidence, :map
    field :expected_effects, {:array, :string}
    field :consequence_bounds, {:array, :string}
    field :provenance, :map
    field :prepared_at, :utc_datetime_usec
    field :sent_or_unknown_at, :utc_datetime_usec

    belongs_to :operator, SpaceTraders.Agent.Operator, type: :id
    belongs_to :agent, SpaceTraders.Agent.Agent, type: :id
    belongs_to :fleet_generation, SpaceTraders.FleetGeneration.Generation, type: :id
    belongs_to :strategy_revision, SpaceTraders.FleetStrategy.Revision, type: :id

    has_many :outcomes, SpaceTraders.MutationAttempts.Outcome,
      foreign_key: :mutation_attempt_id,
      preload_order: [asc: :recorded_at, asc: :id]

    timestamps(type: :utc_datetime_usec)
  end
end
