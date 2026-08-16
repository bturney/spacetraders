defmodule SpaceTraders.Repo.Migrations.AddStaleAtToAgents do
  use Ecto.Migration

  def change do
    alter table(:agents) do
      add :stale_at, :utc_datetime
    end

    create index(:agents, [:operator_id, :stale_at])
  end
end
