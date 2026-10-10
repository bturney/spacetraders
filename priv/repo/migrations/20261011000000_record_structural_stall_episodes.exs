defmodule SpaceTraders.Repo.Migrations.RecordStructuralStallEpisodes do
  use Ecto.Migration

  @moduledoc """
  Durable, deduplicated structural stall dispositions for Fleet Allocation
  (#684, #686; ADR 0012 amendment).

  Expansion only: a fourth episode kind, `structural_stall`, and its fields.
  One open stall Episode per Fleet Generation holds the binding reason and the
  stalled Portfolio; an unchanged condition refreshes `last_observed_at` and
  `observation_count` in place, so a stall observed every reconciliation tick
  stays one row. `resolved_at` closes it on a material transition. Like
  `publication_rejected`, the kind is never a selection kind: the allocation
  result pointer keeps its own check.

  Compatibility: a pre-#686 binary ignores the columns and never writes the
  kind; rows it reads with the new kind fall outside its Ecto enum, so roll the
  binary back only together with `down/0`, which deletes the stall Episodes
  (their only durable record) and restores the previous checks.
  """

  def up do
    alter table(:strategy_decision_episodes) do
      add :stall_reason, :string

      add :stalled_portfolio_id,
          references(:fleet_commitment_portfolios, on_delete: :nilify_all)

      add :last_observed_at, :utc_datetime_usec
      add :observation_count, :integer
      add :resolved_at, :utc_datetime_usec
    end

    drop constraint(:strategy_decision_episodes, :selection_kind_allowed)
    drop constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection)

    create constraint(:strategy_decision_episodes, :selection_kind_allowed,
             check:
               "selection_kind IN ('selected_plan', 'neutral_wait', 'publication_rejected', 'structural_stall')"
           )

    create constraint(:strategy_decision_episodes, :neutral_wait_fields_match_selection,
             check: """
             (selection_kind = 'selected_plan' AND binding_limitation_kind IS NULL
              AND next_observation_at IS NULL AND rejection_reason IS NULL
              AND stall_reason IS NULL)
             OR
             (selection_kind = 'neutral_wait'
              AND binding_limitation_kind IN (
                'incomplete_coverage',
                'no_admissible_candidate',
                'below_economic_threshold',
                'awaiting_scheduled_evidence'
              )
              AND next_observation_at IS NOT NULL AND rejection_reason IS NULL
              AND stall_reason IS NULL)
             OR
             (selection_kind = 'publication_rejected' AND binding_limitation_kind IS NULL
              AND next_observation_at IS NULL AND rejection_reason IS NOT NULL
              AND stall_reason IS NULL)
             OR
             (selection_kind = 'structural_stall' AND binding_limitation_kind IS NULL
              AND next_observation_at IS NULL AND rejection_reason IS NULL
              AND stall_reason IN (
                'stale_revision_portfolio',
                'authority_blocked_intent',
                'overdue_demands_without_coverage'
              )
              AND last_observed_at IS NOT NULL AND observation_count >= 1)
             """
           )

    create unique_index(:strategy_decision_episodes, [:fleet_generation_id],
             where: "selection_kind = 'structural_stall' AND resolved_at IS NULL",
             name: :strategy_decision_episodes_one_open_stall
           )
  end

  def down do
    execute("DELETE FROM strategy_decision_episodes WHERE selection_kind = 'structural_stall'")

    drop index(:strategy_decision_episodes, [:fleet_generation_id],
           name: :strategy_decision_episodes_one_open_stall
         )

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

    alter table(:strategy_decision_episodes) do
      remove :stall_reason
      remove :stalled_portfolio_id
      remove :last_observed_at
      remove :observation_count
      remove :resolved_at
    end
  end
end
