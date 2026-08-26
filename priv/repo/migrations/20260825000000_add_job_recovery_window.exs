defmodule SpaceTraders.Repo.Migrations.AddJobRecoveryWindow do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :recovery_started_at, :utc_datetime
    end
  end
end
