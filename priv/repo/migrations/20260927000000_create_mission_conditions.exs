defmodule SpaceTraders.Repo.Migrations.CreateMissionConditions do
  use Ecto.Migration

  def change do
    create table(:mission_conditions) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :kind, :string, null: false
      add :summary, :text, null: false
      add :acknowledged_at, :utc_datetime_usec
      add :resolved_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:mission_conditions, [:operator_id, :key],
             where: "resolved_at IS NULL",
             name: :mission_conditions_unresolved_key_index
           )

    create index(:mission_conditions, [:operator_id, :resolved_at])
  end
end
