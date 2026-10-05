defmodule SpaceTraders.Repo.Migrations.BindObservationGeneration do
  use Ecto.Migration

  def change do
    alter table(:authoritative_observations) do
      add :fleet_generation_id, references(:fleet_generations, on_delete: :nilify_all)
    end
  end
end
