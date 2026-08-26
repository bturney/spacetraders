defmodule SpaceTraders.Repo.Migrations.CreateOperationalIntelligence do
  use Ecto.Migration

  def change do
    create table(:intelligence_observations) do
      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :observing_ship_symbol, :string
      add :source, :string, null: false
      add :subject_type, :string, null: false
      add :subject_system_symbol, :string
      add :subject_symbol, :string, null: false
      add :observed_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:intelligence_observations, [
             :agent_id,
             :subject_type,
             :subject_system_symbol,
             :subject_symbol,
             :observed_at
           ])

    create table(:intelligence_facts) do
      add :observation_id, references(:intelligence_observations, on_delete: :delete_all),
        null: false

      add :agent_id, references(:agents, on_delete: :delete_all), null: false
      add :subject_type, :string, null: false
      add :subject_system_symbol, :string
      add :subject_symbol, :string, null: false
      add :field, :string, null: false
      add :state, :string, null: false
      add :value, :map
      add :invalidated_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:intelligence_facts, [
             :agent_id,
             :subject_type,
             :subject_system_symbol,
             :subject_symbol,
             :field,
             :invalidated_at
           ])
  end
end
