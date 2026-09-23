defmodule SpaceTraders.Repo.Migrations.AddActualOutcomesToStrategyDecisionEpisodes do
  use Ecto.Migration

  def change do
    alter table(:strategy_decision_episodes) do
      add :actual_outcomes, :map, null: false, default: %{}
    end
  end
end
