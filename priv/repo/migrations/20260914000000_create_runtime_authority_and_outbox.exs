defmodule SpaceTraders.Repo.Migrations.CreateRuntimeAuthorityAndOutbox do
  use Ecto.Migration

  def change do
    create table(:runtime_authority, primary_key: false) do
      add :name, :string, primary_key: true
      add :store, :string, null: false
      add :advanced_at, :utc_datetime_usec, null: false
    end

    create table(:outbox_notifications) do
      add :topic, :string, null: false
      add :event, :string, null: false
      add :payload, :map, null: false, default: %{}
      add :delivered_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_notifications, [:delivered_at, :id])
  end
end
