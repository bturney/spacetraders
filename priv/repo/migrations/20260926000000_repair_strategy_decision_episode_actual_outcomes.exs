defmodule SpaceTraders.Repo.Migrations.RepairStrategyDecisionEpisodeActualOutcomes do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_schema = 'public'
          AND table_name = 'strategy_decision_episodes'
          AND column_name = 'actual_outcomes'
      ) THEN
        ALTER TABLE strategy_decision_episodes
          ADD COLUMN actual_outcomes jsonb NOT NULL DEFAULT '{}'::jsonb;
      END IF;
    END
    $$;
    """)
  end

  def down do
    execute("ALTER TABLE strategy_decision_episodes DROP COLUMN IF EXISTS actual_outcomes")
  end
end
