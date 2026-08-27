defmodule SpaceTraders.Repo.Migrations.AddParametersToManualIntents do
  use Ecto.Migration

  def change do
    alter table(:manual_intents) do
      add :parameters, :map, null: false, default: %{}
    end
  end
end
