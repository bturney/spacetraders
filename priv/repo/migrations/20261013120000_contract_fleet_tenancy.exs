defmodule SpaceTraders.Repo.Migrations.ContractFleetTenancy do
  use Ecto.Migration

  def up do
    execute(
      "LOCK TABLE operators, agents, fleet_generations, fleet_strategies, fleet_strategy_revisions, current_fleet_identity IN SHARE ROW EXCLUSIVE MODE"
    )

    # Run the expand-phase preflight before any irreversible relationship change.
    execute("SELECT * FROM fleet_identity_candidate()")

    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM fleet_identity_candidate() c
                 JOIN current_fleet_identity i ON i.id = 1
                 WHERE i.operator_id IS DISTINCT FROM c.operator_id
                    OR i.fleet_generation_id IS DISTINCT FROM c.generation_id)
         OR NOT EXISTS (SELECT 1 FROM current_fleet_identity WHERE id = 1)
      THEN
        RAISE EXCEPTION 'Current Fleet preflight: unpublished or inconsistent current identity'
          USING HINT = 'Resolve the published Fleet identity explicitly before rerunning contraction. No credentials or history were changed.';
      END IF;
    END $$
    """)

    # operator_id remains immutable authorship/causal attribution, not a tenant
    # association. Deleting authentication must never cascade through game history.
    for table <-
          ~w(agents fleet_strategies fleet_generations strategy_decision_episodes fleet_commitment_portfolios allocation_result_pointers ship_reservations mission_conditions mutation_attempts) do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{table}_operator_id_fkey")
    end

    drop index(:agents, [:operator_id])
    drop index(:agents, [:operator_id, :stale_at])
    drop index(:fleet_strategies, [:operator_id])
    drop index(:fleet_generations, [:operator_id, :number])
    drop index(:fleet_generations, [:operator_id, :retired_at])
    drop index(:strategy_decision_episodes, [:operator_id, :inserted_at])
    drop index(:fleet_commitment_portfolios, [:operator_id, :superseded_at])
    drop index(:allocation_result_pointers, [:operator_id])
    drop index(:mission_conditions, [:operator_id, :resolved_at])

    drop index(:mission_conditions, [:operator_id, :key],
           name: :mission_conditions_unresolved_key_index
         )

    create unique_index(:fleet_generations, [:number])
    execute("CREATE UNIQUE INDEX fleet_strategies_singleton_index ON fleet_strategies ((true))")

    create unique_index(:mission_conditions, [:key],
             where: "resolved_at IS NULL",
             name: :mission_conditions_unresolved_key_index
           )

    execute(
      "ALTER TABLE current_fleet_identity DROP CONSTRAINT current_fleet_identity_operator_id_fkey"
    )

    execute(
      "ALTER TABLE current_fleet_identity ADD CONSTRAINT current_fleet_identity_operator_id_fkey FOREIGN KEY (operator_id) REFERENCES operators(id) ON DELETE RESTRICT"
    )

    execute(
      "ALTER TABLE current_fleet_identity DROP CONSTRAINT current_fleet_identity_fleet_generation_id_fkey"
    )

    execute(
      "ALTER TABLE current_fleet_identity ADD CONSTRAINT current_fleet_identity_fleet_generation_id_fkey FOREIGN KEY (fleet_generation_id) REFERENCES fleet_generations(id) ON DELETE RESTRICT"
    )

    alter table(:current_fleet_identity) do
      add :contract_version, :integer, null: false, default: 1
    end

    create constraint(:current_fleet_identity, :current_fleet_contract_version,
             check: "contract_version = 1"
           )

    # Boot and reads validate the published identity; they never adopt raw legacy
    # writers, manufacture a Generation, or select by newest/symbol occupancy.
    execute("DROP FUNCTION fleet_identity_candidate()")

    execute("""
    CREATE FUNCTION preflight_current_fleet()
    RETURNS boolean LANGUAGE plpgsql STABLE AS $$
    DECLARE owner_id bigint; current_id bigint; candidate_id bigint; candidate_count integer;
    BEGIN
      IF (SELECT count(*) FROM operators) > 1 THEN
        RAISE EXCEPTION 'Current Fleet preflight: multiple plausible Operators'
          USING HINT = 'Resolve deployment Operator ownership explicitly. No records were selected or deleted.';
      END IF;
      SELECT id INTO owner_id FROM operators;
      SELECT fleet_generation_id INTO current_id FROM current_fleet_identity
        WHERE id = 1 AND contract_version = 1 AND operator_id IS NOT DISTINCT FROM owner_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Current Fleet preflight: unpublished or inconsistent current identity'
          USING HINT = 'Complete the migration or resolve the published identity explicitly before starting autonomous gameplay.';
      END IF;
      IF EXISTS (SELECT 1 FROM agents a WHERE a.operator_id IS NULL)
         OR EXISTS (SELECT 1 FROM agents a LEFT JOIN fleet_generations g ON g.agent_id = a.id WHERE g.id IS NULL)
         OR EXISTS (SELECT 1 FROM fleet_generations g JOIN agents a ON a.id = g.agent_id WHERE g.operator_id <> a.operator_id)
         OR EXISTS (SELECT 1 FROM fleet_generations g WHERE g.retired_at IS NULL AND g.agent_id IS NULL)
         OR EXISTS (SELECT 1 FROM fleet_generations g JOIN fleet_strategy_revisions r ON r.id = g.fleet_strategy_revision_id
                    JOIN fleet_strategies s ON s.id = r.fleet_strategy_id WHERE g.operator_id <> s.operator_id)
         OR EXISTS (SELECT 1 FROM fleet_strategies s LEFT JOIN fleet_strategy_revisions r ON r.id = s.active_revision_id
                    WHERE s.active_revision_id IS NOT NULL AND (r.id IS NULL OR r.fleet_strategy_id <> s.id))
      THEN
        RAISE EXCEPTION 'Current Fleet preflight: ambiguous Agent, Generation or Strategy provenance'
          USING HINT = 'Resolve missing or inconsistent provenance explicitly. Credentials and history remain untouched.';
      END IF;
      SELECT count(*), min(id) INTO candidate_count, candidate_id FROM fleet_generations WHERE retired_at IS NULL;
      IF candidate_count > 1 THEN
        RAISE EXCEPTION 'Current Fleet preflight: multiple plausible current Agents'
          USING HINT = 'Retire competing Generations explicitly; never choose by symbol or newest record.';
      END IF;
      -- A published retired predecessor is a valid fenced transition with no
      -- allocatable resources; unpublished successors cannot become authority.
      IF candidate_count = 1 AND current_id IS DISTINCT FROM candidate_id THEN
        RAISE EXCEPTION 'Current Fleet preflight: unpublished or inconsistent current identity'
          USING HINT = 'Resolve the current Generation explicitly before starting autonomous gameplay.';
      END IF;
      RETURN true;
    END $$
    """)

    execute("SELECT preflight_current_fleet()")
  end

  def down do
    raise "Fleet tenancy contraction is irreversible. Restore a pre-contraction backup rather than guessing historical ownership."
  end
end
