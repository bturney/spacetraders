defmodule SpaceTraders.Repo.Migrations.AddSurveyProvenance do
  use Ecto.Migration

  def change do
    alter table(:surveys) do
      add :source, :string, null: false, default: "survey"
      add :observing_ship_symbol, :string
      # SQLite cannot add a column with a non-constant default. New Survey
      # writes always supply this value; the nullable column preserves upgrades.
      add :observed_at, :utc_datetime
    end
  end
end
