defmodule SpaceTraders.Repo.Migrations.CreateEarningsRecords do
  use Ecto.Migration

  # One row per completed piece of earning work (#766). Trading writes one per
  # Completed Round Trip, keyed by its Fleet Commitment.
  def change do
    create table(:earnings_records) do
      add :source, :string, null: false
      add :fleet_generation_id, references(:fleet_generations, on_delete: :delete_all),
        null: false

      add :fleet_commitment_id, references(:fleet_commitments, on_delete: :delete_all)
      add :strategy_decision_episode_id, :bigint
      add :ship_symbol, :string, null: false
      add :ship_type, :string, null: false
      add :good, :string, null: false
      add :source_waypoint, :string
      add :destination_waypoint, :string
      add :units, :integer, null: false
      add :jettisoned_units, :integer, null: false, default: 0
      add :revenue, :bigint, null: false
      add :goods_cost, :bigint, null: false
      add :fuel_cost, :bigint, null: false
      add :other_cost, :bigint, null: false
      add :net_earnings, :bigint, null: false
      add :expected_value, :bigint
      add :expected_net_per_ship_hour, :float
      add :price_age_seconds, :integer
      add :alternatives, {:array, :map}, null: false, default: []
      add :ship_seconds, :integer, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:earnings_records, [:fleet_commitment_id])
    create index(:earnings_records, [:fleet_generation_id, :finished_at])
    create index(:earnings_records, [:strategy_decision_episode_id])
  end
end
