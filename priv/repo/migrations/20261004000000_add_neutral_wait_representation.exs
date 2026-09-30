defmodule SpaceTraders.Repo.Migrations.AddNeutralWaitRepresentation do
  use Ecto.Migration

  @doc """
  Neutral Wait representation for Strategy Decision Episodes (ADR 0012).

  Every existing episode selected a plan, so the additive selection kind
  defaults to `selected_plan`. The Neutral-specific limitation kind and next
  observation time stay nil for selected plans. The pointer table holds the
  current allocation result per Fleet Generation and copies no facts: it
  references the episode only.
  """
  def change do
    alter table(:strategy_decision_episodes) do
      add :selection_kind, :string, null: false, default: "selected_plan"
      add :binding_limitation_kind, :string
      add :next_observation_at, :utc_datetime_usec
    end

    # Neutral Wait episodes retain one candidate-bundle map where selected-plan
    # episodes retain the rejected alternatives list. Widen the column from a
    # jsonb array to jsonb; `to_jsonb` preserves every existing list as the
    # same JSON array value.
    execute(
      "ALTER TABLE strategy_decision_episodes ALTER COLUMN alternatives DROP DEFAULT",
      "ALTER TABLE strategy_decision_episodes ALTER COLUMN alternatives DROP DEFAULT"
    )

    execute(
      """
      ALTER TABLE strategy_decision_episodes
        ALTER COLUMN alternatives TYPE jsonb USING to_jsonb(alternatives)
      """,
      """
      ALTER TABLE strategy_decision_episodes
        ALTER COLUMN alternatives TYPE jsonb[] USING CASE
          WHEN jsonb_typeof(alternatives) = 'array'
            THEN (SELECT array_agg(element) FROM jsonb_array_elements(alternatives) element)
          ELSE ARRAY[]::jsonb[] END
      """
    )

    execute(
      "ALTER TABLE strategy_decision_episodes ALTER COLUMN alternatives SET DEFAULT '[]'::jsonb",
      "ALTER TABLE strategy_decision_episodes ALTER COLUMN alternatives SET DEFAULT '{}'::jsonb[]"
    )

    create constraint(:strategy_decision_episodes, :selection_kind_allowed,
             check: "selection_kind IN ('selected_plan', 'neutral_wait')"
           )

    create constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection,
             check: """
             (selection_kind = 'selected_plan' AND binding_limitation_kind IS NULL AND next_observation_at IS NULL)
             OR
             (selection_kind = 'neutral_wait'
              AND binding_limitation_kind IN (
                'incomplete_coverage',
                'no_admissible_candidate',
                'below_economic_threshold',
                'awaiting_scheduled_evidence'
              )
              AND next_observation_at IS NOT NULL)
             """
           )

    create table(:allocation_result_pointers) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false

      add :fleet_generation_id, references(:fleet_generations, on_delete: :delete_all),
        null: false

      add :fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :delete_all),
          null: false

      add :selection_kind, :string, null: false

      add :strategy_decision_episode_id,
          references(:strategy_decision_episodes, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:allocation_result_pointers, [:fleet_generation_id])
    create index(:allocation_result_pointers, [:operator_id])

    create constraint(:allocation_result_pointers, :selection_kind_allowed,
             check: """
             selection_kind IN ('selected_plan', 'neutral_wait')
             AND (selection_kind = 'selected_plan' OR strategy_decision_episode_id IS NOT NULL)
             """
           )

    # Existing current portfolios remain selected allocation results after this
    # additive migration, so make their O(1) pointers available immediately.
    execute(
      """
      INSERT INTO allocation_result_pointers (
        fleet_generation_id,
        operator_id,
        fleet_strategy_revision_id,
        selection_kind,
        strategy_decision_episode_id,
        inserted_at
      )
      SELECT
        fleet_generation_id,
        operator_id,
        fleet_strategy_revision_id,
        'selected_plan',
        strategy_decision_episode_id,
        inserted_at
      FROM fleet_commitment_portfolios
      WHERE superseded_at IS NULL
      ON CONFLICT (fleet_generation_id) DO NOTHING
      """,
      "DELETE FROM allocation_result_pointers"
    )

    execute(
      """
      CREATE FUNCTION clear_wait_pointer_for_episode()
      RETURNS trigger AS $$
      BEGIN
        UPDATE allocation_result_pointers
        SET strategy_decision_episode_id = NULL, selection_kind = 'selected_plan'
        WHERE strategy_decision_episode_id = OLD.id;
        RETURN OLD;
      END;
      $$ LANGUAGE plpgsql
      """,
      "DROP FUNCTION clear_wait_pointer_for_episode()"
    )

    execute(
      """
      CREATE TRIGGER strategy_decision_episodes_clear_pointer
      BEFORE DELETE ON strategy_decision_episodes
      FOR EACH ROW EXECUTE FUNCTION clear_wait_pointer_for_episode()
      """,
      "DROP TRIGGER strategy_decision_episodes_clear_pointer ON strategy_decision_episodes"
    )
  end
end
