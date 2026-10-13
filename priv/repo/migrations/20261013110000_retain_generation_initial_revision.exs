defmodule SpaceTraders.Repo.Migrations.RetainGenerationInitialRevision do
  use Ecto.Migration

  def change do
    alter table(:fleet_generations) do
      # Timestamp precision cannot recover which Revision governed establishment
      # after the active Revision changes. Retain the actual identity for new
      # Generations; existing history is left intact rather than guessed.
      add :initial_fleet_strategy_revision_id,
          references(:fleet_strategy_revisions, on_delete: :nilify_all)
    end
  end
end
