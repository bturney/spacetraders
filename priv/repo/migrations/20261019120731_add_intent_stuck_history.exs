defmodule SpaceTraders.Repo.Migrations.AddIntentStuckHistory do
  use Ecto.Migration

  # When a step last became blocked, and when it last got going again: the
  # "Ship stuck" and "Ship recovered" events of Glance's Just happened feed (#771).
  def change do
    alter table(:intents) do
      add :blocked_at, :utc_datetime
      add :blocked_reason, :string
      add :recovered_at, :utc_datetime
    end

    create index(:intents, [:blocked_at], where: "blocked_at IS NOT NULL")
    create index(:intents, [:recovered_at], where: "recovered_at IS NOT NULL")
  end
end
