defmodule SpaceTraders.Repo.Migrations.AddFleetGenerationStartingCredits do
  use Ecto.Migration

  def change do
    alter table(:fleet_generations) do
      add :starting_credits, :bigint
    end
  end
end
