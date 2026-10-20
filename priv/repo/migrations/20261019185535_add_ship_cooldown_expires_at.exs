defmodule SpaceTraders.Repo.Migrations.AddShipCooldownExpiresAt do
  use Ecto.Migration

  # A Ship's next expected event can be its cooldown end (spec #757 "old").
  def change do
    alter table(:ships) do
      add :cooldown_expires_at, :utc_datetime
    end
  end
end
