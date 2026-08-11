defmodule SpaceTraders.Repo.Migrations.CreateAutopilotConfigs do
  use Ecto.Migration

  def change do
    create table(:autopilot_configs) do
      add :ship_id, references(:ships, on_delete: :delete_all), null: false
      add :extraction_waypoint, :string, null: false
      add :market_waypoint, :string, null: false
      add :cargo_threshold, :integer, null: false
      add :desired_mode, :string, null: false, default: "manual"
      add :status, :string, null: false, default: "ready"
      add :blocked_reason, :string
      add :last_validated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:autopilot_configs, [:ship_id])
  end
end
