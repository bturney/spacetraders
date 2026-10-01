defmodule SpaceTraders.Repo.Migrations.LinkRecordedShipDispatch do
  use Ecto.Migration

  def up do
    alter table(:intents) do
      add :mutation_attempt_id,
          references(:mutation_attempts, type: :uuid, on_delete: :nilify_all)
    end

    create index(:intents, [:mutation_attempt_id])

    replace_states(true)
  end

  def down do
    drop index(:intents, [:mutation_attempt_id])

    alter table(:intents) do
      remove :mutation_attempt_id
    end

    replace_states(false)
  end

  defp replace_states(include_not_sent) do
    suffix = if include_not_sent, do: ", 'not_sent'", else: ""
    drop constraint(:mutation_attempts, :mutation_attempts_state)

    create constraint(:mutation_attempts, :mutation_attempts_state,
             check:
               "state IN ('prepared', 'sent_or_unknown', 'succeeded', 'rejected', 'ambiguous', 'accepted', 'absent', 'bounded_unknown'#{suffix})"
           )

    drop constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification)

    create constraint(:mutation_attempt_outcomes, :mutation_attempt_outcomes_classification,
             check:
               "classification IN ('succeeded', 'rejected', 'ambiguous', 'accepted', 'absent', 'bounded_unknown'#{suffix})"
           )
  end
end
