defmodule SpaceTraders.Repo.Migrations.MigrateAutopilotConfigsToJobs do
  use Ecto.Migration

  def change do
    drop unique_index(:autopilot_configs, [:ship_id])
    rename table(:autopilot_configs), to: table(:jobs)
    create unique_index(:jobs, [:ship_id])

    alter table(:jobs) do
      add :type, :string, null: false, default: "miner"
    end
  end
end
