defmodule SpaceTraders.Repo.Migrations.AddSellableGoodsToJobs do
  use Ecto.Migration

  def change do
    alter table(:jobs) do
      add :sellable_goods, {:array, :string}, null: false, default: []
    end
  end
end
