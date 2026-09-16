defmodule SpaceTraders.Repo.Migrations.CreateMutationAttempts do
  use Ecto.Migration

  def change do
    create table(:mutation_attempts, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :operation_id, :string, null: false
      add :operation_owner, :string, null: false
      add :state, :string, null: false
      add :request_fingerprint, :string, null: false
      add :prepared_evidence, :map, null: false, default: %{}
      add :expected_effects, {:array, :string}, null: false, default: []
      add :consequence_bounds, {:array, :string}, null: false, default: []
      add :provenance, :map, null: false, default: %{}
      add :prepared_at, :utc_datetime_usec, null: false
      add :sent_or_unknown_at, :utc_datetime_usec

      add :operator_id, references(:operators, on_delete: :nilify_all)
      add :agent_id, references(:agents, on_delete: :nilify_all)
      add :fleet_generation_id, references(:fleet_generations, on_delete: :nilify_all)

      add :strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:mutation_attempts, [:agent_id, :prepared_at])
    create index(:mutation_attempts, [:fleet_generation_id, :prepared_at])
    create index(:mutation_attempts, [:strategy_revision_id, :prepared_at])
    create index(:mutation_attempts, [:state])

    create constraint(:mutation_attempts, :mutation_attempts_state,
             check:
               "state IN ('prepared', 'sent_or_unknown', 'succeeded', 'rejected', 'ambiguous', 'reconciled')"
           )

    create table(:mutation_attempt_outcomes) do
      add :mutation_attempt_id,
          references(:mutation_attempts, type: :uuid),
          null: false

      add :classification, :string, null: false
      add :evidence, :map, null: false, default: %{}
      add :recorded_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:mutation_attempt_outcomes, [:mutation_attempt_id, :recorded_at])

    create constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification,
             check: "classification IN ('succeeded', 'rejected', 'ambiguous', 'reconciled')"
           )
  end
end
