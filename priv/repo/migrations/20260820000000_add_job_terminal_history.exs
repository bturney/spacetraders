defmodule SpaceTraders.Repo.Migrations.AddJobTerminalHistory do
  use Ecto.Migration

  def change do
    drop unique_index(:jobs, [:ship_id])

    alter table(:jobs) do
      add :finished_at, :utc_datetime
    end

    execute(
      "UPDATE jobs SET status = CASE WHEN desired_mode = 'active' THEN 'active' ELSE 'paused' END WHERE status = 'ready'",
      "UPDATE jobs SET status = 'ready' WHERE status IN ('active', 'paused')"
    )

    execute(
      "UPDATE jobs SET status = 'active' WHERE status = 'revalidating'",
      "UPDATE jobs SET status = 'revalidating' WHERE status = 'active' AND in_flight_action IS NOT NULL"
    )

    create unique_index(:jobs, [:ship_id],
             where: "status NOT IN ('completed', 'failed', 'stopped', 'replaced')",
             name: :jobs_one_unfinished_per_ship_index
           )
  end
end
