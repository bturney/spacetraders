defmodule SpaceTraders.Repo.Migrations.AddGatherModeToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :gather_mode, :string, null: false, default: "extract"
    end
  end
end
