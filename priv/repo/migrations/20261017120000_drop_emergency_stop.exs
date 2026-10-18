defmodule SpaceTraders.Repo.Migrations.DropEmergencyStop do
  use Ecto.Migration

  def change do
    alter table(:fleet_strategies) do
      remove :emergency_stopped_at, :utc_datetime_usec
      remove :emergency_resume_prepared_at, :utc_datetime_usec
      remove :emergency_stop_version, :integer, null: false, default: 0
    end
  end
end
