defmodule SpaceTraders.Repo.Migrations.ActivateClaimedShipExecution do
  use Ecto.Migration

  def up do
    alter table(:intents) do
      add :fleet_commitment_id, references(:fleet_commitments, on_delete: :nilify_all)

      add :fleet_commitment_portfolio_id,
          references(:fleet_commitment_portfolios, on_delete: :nilify_all)

      add :fleet_commitment_portfolio_version, :integer
    end

    create index(:intents, [:fleet_commitment_id])

    drop_if_exists index(:intents, [:ship_id], name: :intents_one_active_per_ship_index)

    create unique_index(:intents, [:ship_id],
             where: "status NOT IN ('completed', 'infeasible', 'stopped', 'superseded')",
             name: :intents_one_active_per_ship_index
           )
  end

  def down do
    drop_if_exists index(:intents, [:ship_id], name: :intents_one_active_per_ship_index)

    execute("UPDATE intents SET status = 'stopped' WHERE status IN ('infeasible', 'superseded')")

    create unique_index(:intents, [:ship_id],
             where: "status NOT IN ('completed', 'stopped')",
             name: :intents_one_active_per_ship_index
           )

    drop_if_exists index(:intents, [:fleet_commitment_id])

    alter table(:intents) do
      remove :fleet_commitment_portfolio_version
      remove :fleet_commitment_portfolio_id
      remove :fleet_commitment_id
    end
  end
end
