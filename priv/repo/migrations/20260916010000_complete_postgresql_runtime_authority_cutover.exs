defmodule SpaceTraders.Repo.Migrations.CompletePostgresqlRuntimeAuthorityCutover do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO runtime_authority (name, store, advanced_at)
    VALUES ('durable_truth', 'postgresql', CURRENT_TIMESTAMP)
    ON CONFLICT (name) DO UPDATE
    SET store = EXCLUDED.store, advanced_at = EXCLUDED.advanced_at
    """)
  end

  def down do
    execute("DELETE FROM runtime_authority WHERE name = 'durable_truth' AND store = 'postgresql'")
  end
end
