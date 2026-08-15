defmodule SpaceTraders.Repo.Migrations.CreateShipDestinationHistory do
  use Ecto.Migration

  def change do
    create table(:ship_destination_history) do
      add :waypoint_symbol, :string, null: false
      add :position, :integer, null: false
      add :ship_id, references(:ships, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:ship_destination_history, [:ship_id, :waypoint_symbol])
    create index(:ship_destination_history, [:ship_id, :position])
  end
end
