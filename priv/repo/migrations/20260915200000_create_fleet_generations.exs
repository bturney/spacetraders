defmodule SpaceTraders.Repo.Migrations.CreateFleetGenerations do
  use Ecto.Migration

  def change do
    create table(:fleet_generations) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, on_delete: :nilify_all)

      add :fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)

      add :number, :integer, null: false
      add :symbol, :string, null: false
      add :faction, :string, null: false
      add :replacement_symbols, :map, null: false, default: %{}
      add :objective_progress, :map, null: false, default: %{}
      add :strategy_capable_at, :utc_datetime_usec
      add :fenced_at, :utc_datetime_usec
      add :retired_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fleet_generations, [:operator_id, :number])
    create unique_index(:fleet_generations, [:agent_id])
    create index(:fleet_generations, [:operator_id, :retired_at])
    create index(:fleet_generations, [:fleet_strategy_revision_id])
  end
end
