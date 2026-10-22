defmodule SpaceTraders.Repo.Migrations.AddMutationAttemptSequence do
  use Ecto.Migration

  def up do
    alter table(:mutation_attempts) do
      add :sequence, :bigint
    end

    flush()
    execute("CREATE SEQUENCE mutation_attempts_sequence_seq OWNED BY mutation_attempts.sequence")

    # Preserve the previous deterministic history order. A timestamp/UUID tie
    # cannot retrospectively establish the causal order of old attempts.
    execute("""
    UPDATE mutation_attempts AS attempt
    SET sequence = ordered.position
    FROM (
      SELECT id, row_number() OVER (ORDER BY prepared_at, id) AS position
      FROM mutation_attempts
    ) AS ordered
    WHERE attempt.id = ordered.id
    """)

    execute("""
    SELECT setval('mutation_attempts_sequence_seq', COALESCE(MAX(sequence), 0) + 1, false)
    FROM mutation_attempts
    """)

    execute("""
    ALTER TABLE mutation_attempts
    ALTER COLUMN sequence SET DEFAULT nextval('mutation_attempts_sequence_seq'),
    ALTER COLUMN sequence SET NOT NULL
    """)

    create unique_index(:mutation_attempts, [:sequence])
  end

  def down do
    drop index(:mutation_attempts, [:sequence])

    alter table(:mutation_attempts) do
      remove :sequence
    end
  end
end
