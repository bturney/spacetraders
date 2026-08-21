defmodule SpaceTraders.Repo.Migrations.AddContractDeliverablesToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :contract_deliverables, {:array, :map}, null: false, default: []
    end
  end
end
