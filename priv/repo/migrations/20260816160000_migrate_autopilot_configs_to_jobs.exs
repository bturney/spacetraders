defmodule SpaceTraders.Repo.Migrations.MigrateAutopilotConfigsToJobs do
  use Ecto.Migration

  def change do
    rename table(:autopilot_configs), to: table(:jobs)

    alter table(:jobs) do
      add :type, :string, null: false, default: "miner"
    end
  end
end
