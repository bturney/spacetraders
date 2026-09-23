defmodule SpaceTraders.Repo.Migrations.PreserveLegacyGameplayHistory do
  use Ecto.Migration

  def change do
    create table(:legacy_gameplay_history) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :original_id, :bigint, null: false
      add :kind, :string, null: false
      add :agent_symbol, :string, null: false
      add :ship_symbol, :string, null: false
      add :type, :string, null: false
      add :caller, :string
      add :status, :string, null: false
      add :target_waypoint, :string
      add :details, :map, null: false, default: %{}
      add :original_inserted_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:legacy_gameplay_history, [:kind, :original_id])
    create index(:legacy_gameplay_history, [:operator_id, :inserted_at])

    create constraint(:legacy_gameplay_history, :legacy_history_kind,
             check: "kind IN ('job', 'intent')"
           )
  end
end
