defmodule SpaceTraders.Repo.Migrations.AddGatherModeToJobsTest do
  # Migrations execute DDL against the shared repo; nothing else may run
  # concurrently.
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Repo
  alias SpaceTraders.Repo.Migrations.AddGatherModeToJobs

  @migration AddGatherModeToJobs
  @version 2026_08_18_000000

  test "saved Miner Jobs migrate unchanged with extract as their gather mode" do
    assert :ok = Ecto.Migrator.down(Repo, @version, @migration, log: false)

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "MIGRATE-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN"
      })

    ship =
      Repo.insert!(%Ship{
        symbol: "MIGRATE-SHIP",
        ship_type: "SHIP_COMMAND_FRIGATE",
        agent_id: agent.id
      })

    Repo.query!(
      """
      INSERT INTO jobs
        (ship_id, type, extraction_waypoint, market_waypoint, cargo_threshold,
         desired_mode, status, sellable_goods, inserted_at, updated_at)
      VALUES
        (?, 'miner', 'X1-UX81-A2', 'X1-UX81-A1', 30, 'manual', 'ready',
         '[]', datetime('now'), datetime('now'))
      """,
      [ship.id]
    )

    assert :ok = Ecto.Migrator.up(Repo, @version, @migration, log: false)

    assert %{"gather_mode" => "extract", "extraction_waypoint" => "X1-UX81-A2"} =
             Repo.query!("SELECT gather_mode, extraction_waypoint FROM jobs").rows
             |> List.first()
             |> then(fn [gather_mode, extraction_waypoint] ->
               %{"gather_mode" => gather_mode, "extraction_waypoint" => extraction_waypoint}
             end)
  end
end
