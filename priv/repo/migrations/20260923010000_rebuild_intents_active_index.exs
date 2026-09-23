defmodule SpaceTraders.Repo.Migrations.RebuildIntentsActiveIndex do
  use Ecto.Migration

  def up do
    drop_if_exists index(:intents, [:ship_id], name: :intents_one_active_per_ship_index)

    create unique_index(:intents, [:ship_id],
             where: "status NOT IN ('completed', 'infeasible', 'stopped', 'superseded')",
             name: :intents_one_active_per_ship_index
           )
  end

  def down do
    drop_if_exists index(:intents, [:ship_id], name: :intents_one_active_per_ship_index)

    create unique_index(:intents, [:ship_id],
             where: "status NOT IN ('completed', 'stopped')",
             name: :intents_one_active_per_ship_index
           )
  end
end
