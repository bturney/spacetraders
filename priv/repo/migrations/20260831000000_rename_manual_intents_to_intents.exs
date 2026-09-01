defmodule SpaceTraders.Repo.Migrations.RenameManualIntentsToIntents do
  use Ecto.Migration

  def up do
    rename table(:manual_intents), to: table(:intents)

    execute("DROP INDEX manual_intents_one_active_per_ship_index")

    create unique_index(:intents, [:ship_id],
             where: "status NOT IN ('completed', 'stopped')",
             name: :intents_one_active_per_ship_index
           )

    alter table(:intents) do
      add :review_revision, :integer, null: false, default: 0
    end
  end

  def down do
    alter table(:intents) do
      remove :review_revision
    end

    rename table(:intents), to: table(:manual_intents)

    execute("DROP INDEX intents_one_active_per_ship_index")

    create unique_index(:manual_intents, [:ship_id],
             where: "status NOT IN ('completed', 'stopped')",
             name: :manual_intents_one_active_per_ship_index
           )
  end
end
