defmodule SpaceTraders.Repo.Migrations.AddEntityRefToMissionConditions do
  use Ecto.Migration

  def change do
    alter table(:mission_conditions) do
      add :entity_ref, :string
    end
  end
end
