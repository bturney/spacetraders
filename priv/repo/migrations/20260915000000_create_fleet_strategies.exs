defmodule SpaceTraders.Repo.Migrations.CreateFleetStrategies do
  use Ecto.Migration

  def change do
    create table(:fleet_strategies) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :draft_document, :map
      add :draft_source, :string
      add :active_revision_id, :integer

      timestamps(type: :utc_datetime)
    end

    create unique_index(:fleet_strategies, [:operator_id])

    create table(:fleet_strategy_revisions) do
      add :fleet_strategy_id, references(:fleet_strategies, on_delete: :delete_all), null: false
      add :number, :integer, null: false
      add :document, :map, null: false
      add :source, :string, null: false
      add :activated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:fleet_strategy_revisions, [:fleet_strategy_id, :number])
    create index(:fleet_strategy_revisions, [:fleet_strategy_id, :activated_at])
  end
end
