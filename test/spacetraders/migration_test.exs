defmodule SpaceTraders.Repo.Migrations.AddGatherModeToJobsTest do
  # Migrations execute DDL against the shared repo; nothing else may run
  # concurrently.
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.Ship
  alias SpaceTraders.Repo
  alias SpaceTraders.Repo.Migrations.AddCallerOwnershipToManualIntents
  alias SpaceTraders.Repo.Migrations.AddGatherModeToJobs
  alias SpaceTraders.Repo.Migrations.RenameManualIntentsToIntents

  @migration AddGatherModeToJobs
  @version 2026_08_18_000000
  @caller_ownership_migration AddCallerOwnershipToManualIntents
  @caller_ownership_version 2026_08_30_000000
  @rename_migration RenameManualIntentsToIntents
  @rename_version 2026_08_31_000000

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

  test "saved Job-owned Intents retain their caller ownership" do
    assert :ok = Ecto.Migrator.down(Repo, @rename_version, @rename_migration, log: false)

    assert :ok =
             Ecto.Migrator.down(
               Repo,
               @caller_ownership_version,
               @caller_ownership_migration,
               log: false
             )

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "MIGRATE-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN"
      })

    ship =
      Repo.insert!(%Ship{
        symbol: "MIGRATE-SHIP-#{System.unique_integer([:positive])}",
        ship_type: "SHIP_COMMAND_FRIGATE",
        agent_id: agent.id
      })

    Repo.query!(
      """
      INSERT INTO jobs
        (ship_id, type, extraction_waypoint, market_waypoint, cargo_threshold,
         desired_mode, status, sellable_goods, inserted_at, updated_at)
      VALUES
        (?, 'miner', 'X1-UX81-A2', 'X1-UX81-A1', 30, 'manual', 'active',
         '[]', datetime('now'), datetime('now'))
      """,
      [ship.id]
    )

    [[job_id]] = Repo.query!("SELECT id FROM jobs WHERE ship_id = ?", [ship.id]).rows

    Repo.query!(
      """
       INSERT INTO manual_intents
        (ship_id, type, target_waypoint, parameters, status, inserted_at, updated_at)
      VALUES
        (?, 'buy', 'X1-UX81-A1', ?, 'blocked', datetime('now'), datetime('now'))
      """,
      [ship.id, Jason.encode!(%{"caller" => "job", "job_id" => job_id})]
    )

    assert :ok =
             Ecto.Migrator.up(
               Repo,
               @caller_ownership_version,
               @caller_ownership_migration,
               log: false
             )

    assert :ok = Ecto.Migrator.up(Repo, @rename_version, @rename_migration, log: false)

    assert [["job", ^job_id]] =
             Repo.query!("SELECT caller, job_id FROM intents WHERE ship_id = ?", [ship.id]).rows

    assert [[0]] =
             Repo.query!("SELECT review_revision FROM intents WHERE ship_id = ?", [ship.id]).rows
  end
end
