defmodule SpaceTraders.Repo.Migrations.StoreCurrentShipState do
  use Ecto.Migration

  def change do
    alter table(:ships) do
      add :engine_speed, :integer
      add :engine_condition, :float
      add :fuel_capacity, :integer
      add :cargo_capacity, :integer
      add :nav_status, :string
      add :waypoint_symbol, :string
      add :fuel_current, :integer
      add :state_observed_at, :utc_datetime_usec
      add :route_origin, :string
      add :route_destination, :string
      add :route_departed_at, :utc_datetime
      add :route_arrives_at, :utc_datetime
    end

    create table(:ship_cargo) do
      add :ship_id, references(:ships, on_delete: :delete_all), null: false
      add :trade_symbol, :string, null: false
      add :units, :integer, null: false
    end

    create unique_index(:ship_cargo, [:ship_id, :trade_symbol])
  end
end
