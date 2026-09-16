defmodule SpaceTraders.Repo.Migrations.AddMutationSafetyFences do
  use Ecto.Migration

  def up do
    alter table(:mutation_attempts) do
      add :dependency_keys, {:array, :string}, null: false, default: []
      add :admitted_bounded_unknown_ids, {:array, :uuid}, null: false, default: []
      add :retry_authorized, :boolean, null: false, default: false

      add :retry_of_id,
          references(:mutation_attempts, type: :uuid, on_delete: :nilify_all)
    end

    create index(:mutation_attempts, [:retry_of_id])

    execute(
      "CREATE INDEX mutation_attempts_dependency_keys_index ON mutation_attempts USING GIN (dependency_keys)"
    )

    drop constraint(:mutation_attempts, :mutation_attempts_state)

    create constraint(:mutation_attempts, :mutation_attempts_state,
             check:
               "state IN ('prepared', 'sent_or_unknown', 'succeeded', 'rejected', 'ambiguous', 'accepted', 'absent', 'bounded_unknown')"
           )

    drop constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification)

    create constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification,
             check:
               "classification IN ('succeeded', 'rejected', 'ambiguous', 'accepted', 'absent', 'bounded_unknown')"
           )
  end

  def down do
    drop constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification)

    create constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification,
             check: "classification IN ('succeeded', 'rejected', 'ambiguous', 'reconciled')"
           )

    drop constraint(:mutation_attempts, :mutation_attempts_state)

    create constraint(:mutation_attempts, :mutation_attempts_state,
             check:
               "state IN ('prepared', 'sent_or_unknown', 'succeeded', 'rejected', 'ambiguous', 'reconciled')"
           )

    drop index(:mutation_attempts, [:retry_of_id])
    execute("DROP INDEX mutation_attempts_dependency_keys_index")

    alter table(:mutation_attempts) do
      remove :retry_of_id
      remove :retry_authorized
      remove :admitted_bounded_unknown_ids
      remove :dependency_keys
    end
  end
end
