defmodule SpaceTraders.Repo.Migrations.AddObservabilityContextToMissionConditions do
  use Ecto.Migration

  def change do
    alter table(:mission_conditions) do
      add :fleet_generation_id, references(:fleet_generations, on_delete: :nilify_all)

      add :fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)

      add :strategy_decision_episode_id,
          references(:strategy_decision_episodes, on_delete: :nilify_all)
    end

    create index(:mission_conditions, [:fleet_generation_id])
    create index(:mission_conditions, [:fleet_strategy_revision_id])
    create index(:mission_conditions, [:strategy_decision_episode_id])
  end
end
