defmodule SpaceTraders.Repo.Migrations.AddJobTerminalHistory do
  use Ecto.Migration

  @terminal_states "('completed', 'failed', 'stopped', 'replaced')"

  def up do
    drop unique_index(:jobs, [:ship_id])

    alter table(:jobs) do
      add :finished_at, :utc_datetime
      add :blocker, :map
    end

    execute(
      "UPDATE jobs SET status = CASE WHEN desired_mode = 'active' THEN 'active' ELSE 'paused' END WHERE status = 'ready'"
    )

    execute("UPDATE jobs SET status = 'active' WHERE status = 'revalidating'")

    create unique_index(:jobs, [:ship_id],
             where: "status NOT IN #{@terminal_states}",
             name: :jobs_one_unfinished_per_ship_index
           )

    execute("""
    CREATE TRIGGER jobs_terminal_immutable_update
    BEFORE UPDATE ON jobs
    WHEN OLD.status IN #{@terminal_states}
    BEGIN
      SELECT RAISE(ABORT, 'terminal jobs are immutable');
    END
    """)
  end

  def down do
    execute("DROP TRIGGER jobs_terminal_immutable_update")

    drop unique_index(:jobs, [:ship_id], name: :jobs_one_unfinished_per_ship_index)

    # Terminal rows exist only because of this migration's history feature;
    # they cannot be represented without the columns it added. The Agent
    # retirement cascade is the only deletion path for them.
    execute("DELETE FROM jobs WHERE finished_at IS NOT NULL")

    create unique_index(:jobs, [:ship_id])

    alter table(:jobs) do
      remove :blocker
      remove :finished_at
    end

    execute(
      "UPDATE jobs SET status = 'revalidating' WHERE status = 'active' AND in_flight_action IS NOT NULL"
    )

    execute("UPDATE jobs SET status = 'ready' WHERE status IN ('active', 'paused')")
  end
end
