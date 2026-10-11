defmodule SpaceTraders.Repo.Migrations.EstablishCurrentFleetIdentity do
  use Ecto.Migration

  def up do
    # Preflight and adoption share a transaction with schema expansion. Locks also
    # exclude legacy writers; no process-local singleton can protect migration.
    execute(
      "LOCK TABLE operators, agents, fleet_generations, fleet_strategies, fleet_strategy_revisions IN SHARE ROW EXCLUSIVE MODE"
    )

    execute("""
    CREATE FUNCTION fleet_identity_candidate()
    RETURNS TABLE(operator_id bigint, agent_id bigint, generation_id bigint)
    LANGUAGE plpgsql STABLE AS $$
    DECLARE
      owner_id bigint;
      candidate_count integer;
    BEGIN
      IF (SELECT count(*) FROM operators) > 1 THEN
        RAISE EXCEPTION 'Current Fleet preflight: multiple plausible Operators'
          USING HINT = 'Resolve deployment Operator ownership explicitly, then rerun migration. No records were selected or deleted.';
      END IF;
      SELECT id INTO owner_id FROM operators;

      IF EXISTS (SELECT 1 FROM agents a WHERE a.operator_id IS NULL)
         OR EXISTS (SELECT 1 FROM fleet_generations g JOIN agents a ON a.id = g.agent_id
                    WHERE g.operator_id <> a.operator_id)
         OR EXISTS (SELECT 1 FROM fleet_generations g
                    JOIN fleet_strategy_revisions r ON r.id = g.fleet_strategy_revision_id
                    JOIN fleet_strategies s ON s.id = r.fleet_strategy_id
                    WHERE g.operator_id <> s.operator_id)
         OR EXISTS (SELECT 1 FROM fleet_strategies s
                    LEFT JOIN fleet_strategy_revisions r ON r.id = s.active_revision_id
                    WHERE s.active_revision_id IS NOT NULL AND
                          (r.id IS NULL OR r.fleet_strategy_id <> s.id))
         OR EXISTS (SELECT 1 FROM fleet_generations g WHERE g.retired_at IS NULL AND g.agent_id IS NULL)
      THEN
        RAISE EXCEPTION 'Current Fleet preflight: ambiguous Agent, Generation or Strategy ownership'
          USING HINT = 'Resolve missing or inconsistent ownership and unfinished Generations explicitly, then rerun migration. Credentials and history remain untouched.';
      END IF;

      SELECT count(*) INTO candidate_count FROM agents a
        LEFT JOIN fleet_generations g ON g.agent_id = a.id
        WHERE g.id IS NULL OR g.retired_at IS NULL;
      IF candidate_count > 1 THEN
        RAISE EXCEPTION 'Current Fleet preflight: multiple plausible current Agents'
          USING HINT = 'Identify the current Fleet and retire competing Generations explicitly, then rerun migration. Never choose by symbol or newest record.';
      END IF;

      RETURN QUERY SELECT owner_id, a.id, g.id FROM agents a
        LEFT JOIN fleet_generations g ON g.agent_id = a.id
        WHERE g.id IS NULL OR g.retired_at IS NULL;
      IF candidate_count = 0 THEN
        RETURN QUERY SELECT owner_id, NULL::bigint, NULL::bigint;
      END IF;
    END $$
    """)

    # Run before creating identity records or changing existing data.
    execute("SELECT * FROM fleet_identity_candidate()")

    create table(:current_fleet_identity, primary_key: false) do
      add :id, :integer, primary_key: true
      add :operator_id, references(:operators, on_delete: :nilify_all)
      add :fleet_generation_id, references(:fleet_generations, on_delete: :nilify_all)
    end

    create constraint(:current_fleet_identity, :current_fleet_identity_singleton, check: "id = 1")

    execute("""
    INSERT INTO fleet_generations
      (operator_id, agent_id, number, symbol, faction, fleet_strategy_revision_id,
       replacement_symbols, objective_progress, fenced_at, inserted_at, updated_at)
    SELECT a.operator_id, a.id,
           COALESCE((SELECT max(g.number) FROM fleet_generations g WHERE g.operator_id = a.operator_id), 0) + 1,
           a.symbol, a.faction, s.active_revision_id,
           jsonb_build_object('symbols', jsonb_build_array(a.symbol)), '{}'::jsonb,
           a.stale_at, a.inserted_at, CURRENT_TIMESTAMP
    FROM fleet_identity_candidate() c JOIN agents a ON a.id = c.agent_id
    LEFT JOIN fleet_strategies s ON s.operator_id = a.operator_id
    WHERE c.generation_id IS NULL
    """)

    execute("""
    INSERT INTO current_fleet_identity (id, operator_id, fleet_generation_id)
    SELECT 1, operator_id, generation_id FROM fleet_identity_candidate();
    """)
  end

  def down do
    drop table(:current_fleet_identity)
    execute("DROP FUNCTION fleet_identity_candidate()")
    # Adoption-created Generations are meaningful identity; rollback retains them.
  end
end
