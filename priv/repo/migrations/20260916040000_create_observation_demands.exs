defmodule SpaceTraders.Repo.Migrations.CreateObservationDemands do
  use Ecto.Migration

  def change do
    create table(:authoritative_observations, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :subject, :string, null: false
      add :operation_id, :string, null: false
      add :dependency_keys, {:array, :string}, null: false
      add :facts, :map, null: false
      add :response_fingerprint, :string, null: false
      add :observed_at, :utc_datetime_usec, null: false
      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:authoritative_observations, [:agent_id, :subject, :observed_at])

    create table(:observation_demands, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :subject, :string, null: false
      add :required_facts, {:array, :string}, null: false
      add :freshness_seconds, :integer, null: false
      add :deadline_at, :utc_datetime_usec, null: false
      add :owner, :string, null: false
      add :withdrawn_at, :utc_datetime_usec

      add :agent_id, references(:agents, on_delete: :delete_all), null: false

      add :strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)

      add :fulfilled_observation_id,
          references(:authoritative_observations, type: :uuid, on_delete: :nilify_all)

      add :replaces_id,
          references(:observation_demands, type: :uuid, on_delete: :nilify_all)

      timestamps(type: :utc_datetime_usec)
    end

    create index(:observation_demands, [:agent_id, :subject, :deadline_at])
    create index(:observation_demands, [:strategy_revision_id])
    create index(:observation_demands, [:fulfilled_observation_id])
    create unique_index(:observation_demands, [:replaces_id], where: "replaces_id IS NOT NULL")

    create constraint(:observation_demands, :observation_demands_freshness_non_negative,
             check: "freshness_seconds >= 0"
           )

    create constraint(:observation_demands, :observation_demands_required_facts_present,
             check: "cardinality(required_facts) > 0"
           )
  end
end
