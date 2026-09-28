defmodule SpaceTraders.Repo.Migrations.AddDueAtToObservationDemands do
  use Ecto.Migration

  @doc """
  Every future Observation Demand carries `due_at`, the earliest useful
  acquisition time that the durable scheduler wakes planning from. `deadline_at`
  becomes optional and keeps its distinct latest-acceptable meaning.
  """
  def change do
    alter table(:observation_demands) do
      add :due_at, :utc_datetime_usec
    end

    execute(
      "UPDATE observation_demands SET due_at = inserted_at WHERE due_at IS NULL",
      ""
    )

    alter table(:observation_demands) do
      modify :due_at, :utc_datetime_usec, null: false
      modify :deadline_at, :utc_datetime_usec, null: true
    end

    create index(:observation_demands, [:due_at])
  end
end
