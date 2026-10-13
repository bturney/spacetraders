defmodule SpaceTraders.Repo.Migrations.IndexMutationAttemptProvenanceIntentId do
  use Ecto.Migration

  @moduledoc """
  Indexes the join predicate `SpaceTraders.FleetAllocation.TradeProgress`
  uses to find the MutationAttempts issued by an Intent (#714).

  `attempt_charges/1` joins `mutation_attempts.provenance -> 'intent_id'` to
  `to_jsonb(intents.id)`. With no matching index PostgreSQL seq-scans
  `mutation_attempts` once per scoped Intent, so `for_generation/1` exceeded
  the 15 s Repo checkout timeout in production and Mission Control answered
  500. Read the index in `lib/spacetraders/fleet_allocation/trade_progress.ex`.

  Keep the indexed expression byte-identical to the query fragment; changing
  either side retires the index silently.

  `CONCURRENTLY` builds the index without blocking writes, which is why this
  migration runs without a DDL transaction or a migration lock. The index is
  derived state, so `down/0` removes it.
  """

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index "mutation_attempts_provenance_intent_id_index"

  def up do
    # A failed CONCURRENTLY build leaves an invalid index behind under this
    # name. Drop it so a retried deploy rebuilds instead of recording an index
    # the planner cannot use.
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")

    execute("""
    CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
      ON mutation_attempts ((provenance -> 'intent_id'))
    """)
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS #{@index}")
  end
end
