defmodule SpaceTraders.Repo.Migrations.CreateSurveys do
  use Ecto.Migration

  def change do
    create table(:surveys) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :waypoint_symbol, :string, null: false
      add :signature, :string, null: false
      add :symbol, :string, null: false
      add :size, :string, null: false
      add :expiration, :utc_datetime, null: false
      add :deposits, {:array, :map}, null: false, default: []
      add :exhausted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:surveys, [:agent_id, :signature], name: :surveys_agent_signature_index)
    create index(:surveys, [:agent_id, :waypoint_symbol, :expiration, :exhausted_at])
  end
end
