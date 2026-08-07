defmodule SpaceTraders.Repo.Migrations.CreateTimelineEvents do
  use Ecto.Migration

  def change do
    create table(:timeline_events) do
      add :owner_type, :string, null: false
      add :owner_id, :string, null: false
      add :event_type, :string, null: false
      add :due_at, :utc_datetime_usec, null: false
      add :status, :string, null: false, default: "pending"
      add :payload, :map, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:timeline_events, [:owner_type, :owner_id, :event_type, :status])
    create index(:timeline_events, [:due_at])
  end
end
