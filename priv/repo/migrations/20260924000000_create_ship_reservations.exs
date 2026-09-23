defmodule SpaceTraders.Repo.Migrations.CreateShipReservations do
  use Ecto.Migration

  def change do
    create table(:ship_reservations) do
      add :ship_id, references(:ships, on_delete: :nilify_all)
      add :ship_symbol, :string, null: false
      add :operator_id, references(:operators, on_delete: :delete_all), null: false
      add :reason, :text, null: false
      add :released_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:ship_reservations, [:ship_id], where: "released_at IS NULL")

    create constraint(:ship_reservations, :ship_reservation_reason_required,
             check: "length(trim(reason)) > 0"
           )
  end
end
