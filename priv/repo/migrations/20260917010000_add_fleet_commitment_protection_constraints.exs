defmodule SpaceTraders.Repo.Migrations.AddFleetCommitmentProtectionConstraints do
  use Ecto.Migration

  def change do
    alter table(:fleet_commitments) do
      add :unwind_state, :string, null: false, default: "not_required"
    end

    create table(:fleet_commitment_claims) do
      add :fleet_commitment_portfolio_id,
          references(:fleet_commitment_portfolios, on_delete: :delete_all),
          null: false

      add :fleet_commitment_id, references(:fleet_commitments, on_delete: :delete_all),
        null: false

      add :resource, :string, null: false
    end

    create unique_index(:fleet_commitment_claims, [:fleet_commitment_portfolio_id, :resource])
    create index(:fleet_commitment_claims, [:fleet_commitment_id])
  end
end
