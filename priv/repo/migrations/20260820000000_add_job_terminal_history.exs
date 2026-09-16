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

    create_terminal_job_trigger()
  end

  def down do
    drop_terminal_job_trigger()

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

  defp create_terminal_job_trigger do
    execute("""
    CREATE FUNCTION jobs_terminal_immutable_update()
    RETURNS trigger AS $$
    BEGIN
      RAISE EXCEPTION 'terminal jobs are immutable';
    END;
    $$ LANGUAGE plpgsql
    """)

    execute("""
    CREATE TRIGGER jobs_terminal_immutable_update
    BEFORE UPDATE ON jobs
    FOR EACH ROW WHEN (OLD.status IN #{@terminal_states})
    EXECUTE FUNCTION jobs_terminal_immutable_update()
    """)
  end

  defp drop_terminal_job_trigger do
    execute("DROP TRIGGER jobs_terminal_immutable_update ON jobs")
    execute("DROP FUNCTION jobs_terminal_immutable_update()")
  end
end
