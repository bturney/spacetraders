defmodule SpaceTraders.Repo.Migrations.RemoveLegacyJobPersistence do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM jobs
        WHERE status IN ('active', 'waiting', 'blocked', 'paused')
          AND in_flight_action IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM intents
        WHERE caller IN ('manual', 'job')
          AND status IN ('active', 'waiting', 'blocked', 'awaiting_confirmation')
          AND in_flight_action IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'reconcile unresolved legacy gameplay before removing Job persistence';
      END IF;
    END $$
    """)

    execute("DROP TRIGGER IF EXISTS deny_legacy_intent_admission ON intents")
    execute("DROP FUNCTION IF EXISTS deny_legacy_intent_admission()")
    execute("DROP TRIGGER IF EXISTS deny_legacy_job_admission ON jobs")
    execute("DROP FUNCTION IF EXISTS deny_legacy_job_admission()")
    execute("DROP FUNCTION IF EXISTS legacy_gameplay_closed(bigint)")

    alter table(:intents) do
      remove :job_id
      modify :caller, :string, null: false, default: nil
    end

    drop table(:jobs)
    drop table(:legacy_gameplay_history)
  end

  def down do
    raise "legacy Job persistence contraction is irreversible"
  end
end
