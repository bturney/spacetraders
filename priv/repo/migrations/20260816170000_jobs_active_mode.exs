defmodule SpaceTraders.Repo.Migrations.JobsActiveMode do
  use Ecto.Migration

  def change do
    execute("UPDATE jobs SET desired_mode = 'active' WHERE desired_mode = 'autopilot'")
  end
end
