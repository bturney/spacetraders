defmodule SpaceTraders.Repo.Migrations.AddSurveyProvenance do
  use Ecto.Migration

  def change do
    alter table(:surveys) do
      add :source, :string, null: false, default: "survey"
      add :observing_ship_symbol, :string
      add :observed_at, :utc_datetime, null: false, default: fragment("CURRENT_TIMESTAMP")
    end
  end
end
