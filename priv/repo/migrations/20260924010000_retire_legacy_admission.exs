defmodule SpaceTraders.Repo.Migrations.RetireLegacyAdmission do
  use Ecto.Migration

  def up do
    execute("""
    DO $$ BEGIN
      IF EXISTS (
        SELECT 1 FROM jobs j JOIN ships s ON s.id = j.ship_id
        JOIN agents a ON a.id = s.agent_id
        JOIN fleet_strategies fs ON fs.operator_id = a.operator_id
        WHERE fs.active_revision_id IS NOT NULL
          AND j.status IN ('active', 'waiting', 'blocked', 'paused')
          AND j.in_flight_action IS NOT NULL
      ) OR EXISTS (
        SELECT 1 FROM intents i JOIN ships s ON s.id = i.ship_id
        JOIN agents a ON a.id = s.agent_id
        JOIN fleet_strategies fs ON fs.operator_id = a.operator_id
        WHERE fs.active_revision_id IS NOT NULL AND i.caller IN ('manual', 'job')
          AND i.status IN ('active', 'waiting', 'blocked', 'awaiting_confirmation')
          AND i.in_flight_action IS NOT NULL
      ) THEN
        RAISE EXCEPTION 'reconcile in-flight legacy work before retiring gameplay admission';
      END IF;
    END $$
    """)

    execute("""
    UPDATE jobs j SET status = 'stopped', finished_at = now(), updated_at = now(),
      blocked_reason = 'Retired for Fleet Strategy'
    FROM ships s JOIN agents a ON a.id = s.agent_id
      JOIN fleet_strategies fs ON fs.operator_id = a.operator_id
    WHERE j.ship_id = s.id AND fs.active_revision_id IS NOT NULL
      AND j.status IN ('active', 'waiting', 'blocked', 'paused')
    """)

    execute("""
    UPDATE intents i SET status = 'stopped', finished_at = now(), updated_at = now()
    FROM ships s JOIN agents a ON a.id = s.agent_id
      JOIN fleet_strategies fs ON fs.operator_id = a.operator_id
    WHERE i.ship_id = s.id AND fs.active_revision_id IS NOT NULL
      AND i.caller IN ('manual', 'job')
      AND i.status IN ('active', 'waiting', 'blocked', 'awaiting_confirmation')
    """)

    execute("""
    CREATE FUNCTION legacy_gameplay_closed(p_ship_id bigint) RETURNS boolean AS $$
    DECLARE active boolean;
    BEGIN
      -- Share the Strategy row lock with activation. An admission already in
      -- progress finishes before activation drains Jobs; a later one observes
      -- the active Revision and is refused.
      SELECT fs.active_revision_id IS NOT NULL INTO active
      FROM ships s JOIN agents a ON a.id = s.agent_id
        JOIN fleet_strategies fs ON fs.operator_id = a.operator_id
      WHERE s.id = p_ship_id FOR SHARE OF fs;
      RETURN COALESCE(active, false);
    END;
    $$ LANGUAGE plpgsql VOLATILE
    """)

    execute("""
    CREATE FUNCTION deny_legacy_job_admission() RETURNS trigger AS $$
    BEGIN
      IF legacy_gameplay_closed(NEW.ship_id) AND
         (TG_OP = 'INSERT' OR (NEW.status IN ('active', 'waiting') AND
           OLD.status IS DISTINCT FROM NEW.status)) THEN
        RAISE EXCEPTION 'legacy Job admission retired' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER deny_legacy_job_admission BEFORE INSERT OR UPDATE ON jobs
    FOR EACH ROW EXECUTE FUNCTION deny_legacy_job_admission()
    """)

    execute("""
    CREATE FUNCTION deny_legacy_intent_admission() RETURNS trigger AS $$
    BEGIN
      IF TG_OP = 'UPDATE' AND OLD.caller IS DISTINCT FROM NEW.caller THEN
        RAISE EXCEPTION 'Intent caller is immutable' USING ERRCODE = '23514';
      END IF;
      IF NEW.caller IN ('manual', 'job') AND legacy_gameplay_closed(NEW.ship_id) AND
         (TG_OP = 'INSERT' OR (OLD.status IS DISTINCT FROM NEW.status AND
           NEW.status IN ('active', 'waiting', 'awaiting_confirmation'))) THEN
        RAISE EXCEPTION 'legacy Intent admission retired' USING ERRCODE = '23514';
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER deny_legacy_intent_admission BEFORE INSERT OR UPDATE ON intents
    FOR EACH ROW EXECUTE FUNCTION deny_legacy_intent_admission()
    """)
  end

  def down do
    execute("DROP TRIGGER deny_legacy_intent_admission ON intents")
    execute("DROP FUNCTION deny_legacy_intent_admission()")
    execute("DROP TRIGGER deny_legacy_job_admission ON jobs")
    execute("DROP FUNCTION deny_legacy_job_admission()")
    execute("DROP FUNCTION legacy_gameplay_closed(bigint)")
  end
end
