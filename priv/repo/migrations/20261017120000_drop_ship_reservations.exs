defmodule SpaceTraders.Repo.Migrations.DropShipReservations do
  use Ecto.Migration

  # Ship Reservation retired (ADR 0017). Manual interventions referenced it by
  # foreign key; IF EXISTS keeps this order-safe against their own retirement.
  def up do
    execute "ALTER TABLE IF EXISTS manual_interventions DROP COLUMN IF EXISTS ship_reservation_id"
    execute "DROP TABLE IF EXISTS ship_reservations"
  end

  def down, do: :ok
end
