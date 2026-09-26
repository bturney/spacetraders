defmodule SpaceTraders.Repo.Migrations.AllowSubgraphCommitmentReplacement do
  use Ecto.Migration

  def change do
    alter table(:fleet_commitments) do
      add :replan_decision_episode_id,
          references(:strategy_decision_episodes, on_delete: :nilify_all)
    end

    create index(:fleet_commitments, [:replan_decision_episode_id])

    drop unique_index(:fleet_commitments, [:fleet_commitment_portfolio_id, :candidate_id])

    create unique_index(:fleet_commitments, [:fleet_commitment_portfolio_id, :candidate_id],
             where: "unwind_state = 'not_required'"
           )
  end
end
