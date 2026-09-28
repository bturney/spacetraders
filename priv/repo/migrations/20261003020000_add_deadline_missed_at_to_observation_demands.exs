defmodule SpaceTraders.Repo.Migrations.AddDeadlineMissedAtToObservationDemands do
  use Ecto.Migration

  @doc """
  Durable missed-deadline limitation.

  A missed optional deadline never removes an open demand: the scheduler marks
  the historical instant here, the demand stays open, and late authoritative
  evidence may still fulfil it. The marker preserves the limitation history
  without introducing any UI or Neutral Wait semantics.
  """
  def change do
    alter table(:observation_demands) do
      add :deadline_missed_at, :utc_datetime_usec
    end
  end
end
