defmodule SpaceTraders.Repo.Migrations.RetainServerResetPredecessors do
  use Ecto.Migration

  # A Server Reset replacement may reuse its predecessor's Agent and Ship
  # symbols. The predecessor's rows stay as attributable history, so symbols
  # are unique only among Agents that are not Stale and Ships not retired.
  def up do
    alter table(:ships) do
      add :retired_at, :utc_datetime
    end

    execute("""
    UPDATE ships AS ship
    SET retired_at = generation.retired_at
    FROM fleet_generations AS generation
    WHERE generation.agent_id = ship.agent_id AND generation.retired_at IS NOT NULL
    """)

    drop unique_index(:agents, [:symbol])
    create unique_index(:agents, [:symbol], where: "stale_at IS NULL")

    drop unique_index(:ships, [:symbol])
    create unique_index(:ships, [:symbol], where: "retired_at IS NULL")
  end

  def down do
    drop unique_index(:ships, [:symbol])
    create unique_index(:ships, [:symbol])

    drop unique_index(:agents, [:symbol])
    create unique_index(:agents, [:symbol])

    alter table(:ships) do
      remove :retired_at
    end
  end
end
