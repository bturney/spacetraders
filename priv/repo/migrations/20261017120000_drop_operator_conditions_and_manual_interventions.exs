defmodule SpaceTraders.Repo.Migrations.DropOperatorConditionsAndManualInterventions do
  use Ecto.Migration

  # ADR 0017: Attention, Intervention and Manual Intervention are retired. The
  # history is discarded with the cutover's fresh Fleet Generation.
  def up do
    execute("DROP TRIGGER IF EXISTS preserve_manual_intervention_history ON intents")
    execute("DROP FUNCTION IF EXISTS preserve_manual_intervention_history()")

    drop table(:manual_interventions)
    drop table(:mission_conditions)

    # No caller drives these Intents any more; leave none unfinished.
    execute("""
    UPDATE intents SET status = 'stopped', finished_at = now()
    WHERE caller = 'intervention'
      AND status IN ('active', 'waiting', 'awaiting_confirmation', 'blocked')
    """)
  end

  def down, do: raise(Ecto.MigrationError, "retired tables are not restored (ADR 0017)")
end
