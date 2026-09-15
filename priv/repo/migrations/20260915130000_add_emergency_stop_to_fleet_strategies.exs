defmodule SpaceTraders.Repo.Migrations.AddEmergencyStopToFleetStrategies do
  use Ecto.Migration

  def change do
    alter table(:fleet_strategies) do
      add :emergency_stopped_at, :utc_datetime_usec
      add :emergency_stop_version, :integer, null: false, default: 0
    end
  end
end
