defmodule SpaceTraders.Repo.Migrations.CreateFleetCommitmentPortfolios do
  use Ecto.Migration

  def change do
    alter table(:fleet_generations) do
      add :allocation_version, :integer, null: false, default: 0
    end

    create table(:strategy_decision_episodes) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false

      add :fleet_generation_id, references(:fleet_generations, on_delete: :delete_all),
        null: false

      add :fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :delete_all),
          null: false

      add :source_version, :integer, null: false
      add :evidence_references, {:array, :map}, null: false, default: []
      add :alternatives, {:array, :map}, null: false, default: []
      add :binding_constraints, {:array, :map}, null: false, default: []
      add :expectations, :map, null: false, default: %{}
      add :calibration_version, :string, null: false
      add :classification, :string, null: false, default: "still_evaluating"

      timestamps(type: :utc_datetime_usec)
    end

    create index(:strategy_decision_episodes, [:operator_id, :inserted_at])
    create index(:strategy_decision_episodes, [:fleet_generation_id])
    create index(:strategy_decision_episodes, [:fleet_strategy_revision_id])

    create table(:fleet_commitment_portfolios) do
      add :operator_id, references(:operators, on_delete: :delete_all), null: false

      add :fleet_generation_id, references(:fleet_generations, on_delete: :delete_all),
        null: false

      add :fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :delete_all),
          null: false

      add :strategy_decision_episode_id,
          references(:strategy_decision_episodes, on_delete: :delete_all),
          null: false

      add :version, :integer, null: false
      add :superseded_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:fleet_commitment_portfolios, [:fleet_generation_id, :version])

    create unique_index(:fleet_commitment_portfolios, [:fleet_generation_id],
             where: "superseded_at IS NULL",
             name: :fleet_commitment_portfolios_current_generation_index
           )

    create index(:fleet_commitment_portfolios, [:operator_id, :superseded_at])
    create unique_index(:fleet_commitment_portfolios, [:strategy_decision_episode_id])

    create table(:fleet_commitments) do
      add :fleet_commitment_portfolio_id,
          references(:fleet_commitment_portfolios, on_delete: :delete_all),
          null: false

      add :candidate_id, :string, null: false
      add :objective_index, :integer, null: false
      add :claims, {:array, :string}, null: false, default: []
      add :reservations, :map, null: false, default: %{}
      add :pledges, {:array, :map}, null: false, default: []
      add :dependencies, {:array, :map}, null: false, default: []
      add :expected_value, :float, null: false
      add :unwind_cost, :float, null: false
      add :decisive_reason, :text, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:fleet_commitments, [:fleet_commitment_portfolio_id, :candidate_id])
    create index(:fleet_commitments, [:fleet_commitment_portfolio_id, :objective_index])
  end
end
