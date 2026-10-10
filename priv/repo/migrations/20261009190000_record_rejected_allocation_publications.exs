defmodule SpaceTraders.Repo.Migrations.RecordRejectedAllocationPublications do
  use Ecto.Migration

  @moduledoc """
  Durable Strategy Decision Episodes for rejected Fleet Allocation
  publications (#671).

  Expansion only: one nullable `rejection_reason` column and a widened
  `selection_kind` check admitting `publication_rejected`. Existing rows are
  untouched and keep a NULL reason. The allocation result pointer keeps its
  own `selected_plan`/`neutral_wait` check: a rejected publication never
  becomes the current result.

  Compatibility: a pre-#671 binary ignores the column and never writes the
  new kind; rows it reads with the new kind fall outside its Ecto enum, so
  roll the binary back only together with `down/0`. Rollback deletes the
  rejected-publication episodes (their only durable record) and restores the
  original checks. Fix forward otherwise.
  """

  def up do
    alter table(:strategy_decision_episodes) do
      add :rejection_reason, :string
    end

    drop constraint(:strategy_decision_episodes, :selection_kind_allowed)
    drop constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection)

    create constraint(:strategy_decision_episodes, :selection_kind_allowed,
             check: "selection_kind IN ('selected_plan', 'neutral_wait', 'publication_rejected')"
           )

    create constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection,
             check: """
             (selection_kind = 'selected_plan' AND binding_limitation_kind IS NULL
              AND next_observation_at IS NULL AND rejection_reason IS NULL)
             OR
             (selection_kind = 'neutral_wait'
              AND binding_limitation_kind IN (
                'incomplete_coverage',
                'no_admissible_candidate',
                'below_economic_threshold',
                'awaiting_scheduled_evidence'
              )
              AND next_observation_at IS NOT NULL AND rejection_reason IS NULL)
             OR
             (selection_kind = 'publication_rejected' AND binding_limitation_kind IS NULL
              AND next_observation_at IS NULL AND rejection_reason IS NOT NULL)
             """
           )
  end

  def down do
    execute(
      "DELETE FROM strategy_decision_episodes WHERE selection_kind = 'publication_rejected'"
    )

    drop constraint(:strategy_decision_episodes, :selection_kind_allowed)
    drop constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection)

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

    alter table(:strategy_decision_episodes) do
      remove :rejection_reason
    end
  end
end
