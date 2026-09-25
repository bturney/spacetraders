defmodule SpaceTraders.Repo.Migrations.AddGenerationObservedCredits do
  use Ecto.Migration

  def change do
    alter table(:fleet_generations) do
      add :last_observed_credits, :integer
      add :last_observed_at, :utc_datetime_usec
      add :last_observed_evidence_id, :uuid
    end
  end
end
