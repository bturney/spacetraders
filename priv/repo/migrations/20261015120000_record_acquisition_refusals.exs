defmodule SpaceTraders.Repo.Migrations.RecordAcquisitionRefusals do
  use Ecto.Migration

  # Expand decision evidence, not the current-result pointer's selection kinds.
  # Reuse the existing checks verbatim, adding only the new refusal case.
  def up do
    execute("""
    DO $$
    DECLARE definition text;
    BEGIN
      SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid = 'strategy_decision_episodes'::regclass
          AND conname = 'selection_kind_allowed';
      ALTER TABLE strategy_decision_episodes DROP CONSTRAINT selection_kind_allowed;
      EXECUTE 'ALTER TABLE strategy_decision_episodes ADD CONSTRAINT selection_kind_allowed CHECK (' ||
        substring(definition FROM 8 FOR length(definition) - 8) ||
        ' OR selection_kind = ''acquisition_refused'')';

      SELECT pg_get_constraintdef(oid) INTO definition FROM pg_constraint
        WHERE conrelid = 'strategy_decision_episodes'::regclass
          AND conname = 'neutral_wait_fields_match_selection';
      ALTER TABLE strategy_decision_episodes DROP CONSTRAINT neutral_wait_fields_match_selection;
      EXECUTE 'ALTER TABLE strategy_decision_episodes ADD CONSTRAINT neutral_wait_fields_match_selection CHECK (' ||
        substring(definition FROM 8 FOR length(definition) - 8) ||
        ' OR (selection_kind = ''acquisition_refused'' AND binding_limitation_kind IS NULL
          AND next_observation_at IS NULL AND rejection_reason IS NOT NULL AND stall_reason IS NULL))';
    END $$;
    """)
  end

  def down do
    # Refusal Episodes are history. Do not silently delete them on rollback.
    raise "Acquisition refusal history requires an explicit data-preserving rollback"
  end
end
