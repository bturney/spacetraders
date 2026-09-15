defmodule SpaceTraders.Repo.Migrations.AddEmergencyResumePreparedAt do
  use Ecto.Migration

  def change do
    alter table(:fleet_strategies) do
      add :emergency_resume_prepared_at, :utc_datetime_usec
    end
  end
end
