defmodule SpaceTraders.Repo.Migrations.CreateFleetActivity do
  use Ecto.Migration

  def change do
    create table(:fleet_activity) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :ship_id, references(:ships, on_delete: :delete_all)
      add :kind, :string, null: false
      add :message, :string, null: false
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:fleet_activity, [:agent_id, :inserted_at])
  end
end
