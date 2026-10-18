defmodule SpaceTraders.Repo.Migrations.AddIntentNextAttempt do
  use Ecto.Migration

  # A blocked execution step stores when it is next retried and how often it
  # has been retried while blocked (#767).
  def change do
    alter table(:intents) do
      add :next_attempt_at, :utc_datetime
      add :retries, :integer, null: false, default: 0
    end
  end
end
