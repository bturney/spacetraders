defmodule SpaceTraders.Repo.Migrations.AddAutopilotRecoveryAttempts do
  use Ecto.Migration

  def change do
    alter table(:autopilot_configs) do
      add :recovery_attempts, :integer, null: false, default: 0
    end
  end
end
