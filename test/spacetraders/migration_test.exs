defmodule SpaceTraders.Repo.Migrations.PersistenceRenameTest do
  # Migrations execute DDL against the shared repo; nothing else may run
  # concurrently.
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Fleet.{Intent, Ship}
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

  test "renames every Intent lifecycle state without losing row evidence" do
    assert :ok = Ecto.Migrator.down(Repo, @rename_version, @rename_migration, log: false)

    agent =
      Repo.insert!(%AgentRecord{
        symbol: "MATRIX-#{System.unique_integer([:positive])}",
        faction: "COSMIC",
        headquarters: "X1-UX81-A1",
        agent_token: "AGENT_TOKEN"
      })

    states = ["active", "waiting", "blocked", "completed", "stopped"]

    original_rows =
      for status <- states, caller <- ["manual", "job"] do
        ship =
          Repo.insert!(%Ship{
            symbol: "MATRIX-SHIP-#{System.unique_integer([:positive])}",
            ship_type: "SHIP_COMMAND_FRIGATE",
            agent_id: agent.id
          })

        job_id =
          if caller == "job" do
            Repo.query!(
              "INSERT INTO jobs (ship_id, type, extraction_waypoint, market_waypoint, cargo_threshold, status, sellable_goods, inserted_at, updated_at) VALUES (?, 'miner', 'X1-UX81-A2', 'X1-UX81-A1', 30, 'active', '[]', datetime('now'), datetime('now')) RETURNING id",
              [ship.id]
            ).rows
            |> List.first()
            |> List.first()
          end

        inserted_at = ~U[2026-01-01 00:00:00Z]
        updated_at = ~U[2026-01-02 00:00:00Z]
        finished_at = if status in ["completed", "stopped"], do: updated_at

        [id] =
          Repo.query!(
            "INSERT INTO manual_intents (ship_id, type, target_waypoint, parameters, status, blocker, in_flight_action, last_action_result, recovery_attempts, finished_at, caller, job_id, inserted_at, updated_at) VALUES (?, 'navigate', 'X1-UX81-A1', ?, ?, ?, ?, ?, 2, ?, ?, ?, ?, ?) RETURNING id",
            [
              ship.id,
              Jason.encode!(%{"marker" => "#{caller}-#{status}"}),
              status,
              Jason.encode!(%{"reason" => "#{caller}-#{status}"}),
              Jason.encode!(%{"kind" => "navigate", "marker" => "#{caller}-#{status}"}),
              Jason.encode!(%{"result" => "#{caller}-#{status}"}),
              finished_at,
              caller,
              job_id,
              inserted_at,
              updated_at
            ]
          ).rows
          |> List.first()

        %{
          id: id,
          ship_id: ship.id,
          caller: caller,
          job_id: job_id,
          type: "navigate",
          target_waypoint: "X1-UX81-A1",
          status: status,
          marker: "#{caller}-#{status}",
          inserted_at: inserted_at,
          updated_at: updated_at,
          finished_at: finished_at
        }
      end

    assert :ok = Ecto.Migrator.up(Repo, @rename_version, @rename_migration, log: false)

    assert 10 == Repo.aggregate(Intent, :count, :id)
    assert 10 == Repo.aggregate(Intent, :count, :recovery_attempts)

    assert Enum.sort(Repo.all(from i in Intent, select: i.status)) ==
             Enum.sort(states ++ states)

    migrated_rows =
      Repo.all(
        from i in Intent,
          select: %{
            id: i.id,
            ship_id: i.ship_id,
            caller: i.caller,
            job_id: i.job_id,
            type: i.type,
            target_waypoint: i.target_waypoint,
            status: i.status,
            parameters: i.parameters,
            blocker: i.blocker,
            in_flight_action: i.in_flight_action,
            last_action_result: i.last_action_result,
            recovery_attempts: i.recovery_attempts,
            finished_at: i.finished_at,
            inserted_at: i.inserted_at,
            updated_at: i.updated_at
          }
      )

    assert Enum.sort(Enum.map(original_rows, & &1.id)) ==
             Enum.sort(Enum.map(migrated_rows, & &1.id))

    assert Enum.all?(original_rows, fn original ->
             migrated = Enum.find(migrated_rows, &(&1.id == original.id))
             marker = original.marker

             migrated != nil and migrated.ship_id == original.ship_id and
               migrated.caller == original.caller and
               migrated.job_id == original.job_id and migrated.status == original.status and
               migrated.type == original.type and
               migrated.target_waypoint == original.target_waypoint and
               migrated.parameters["marker"] == marker and
               migrated.blocker.reason == original.caller <> "-" <> original.status and
               migrated.in_flight_action["marker"] == marker and
               migrated.last_action_result["result"] == marker and
               migrated.recovery_attempts == 2 and
               migrated.finished_at == original.finished_at and
               migrated.inserted_at == original.inserted_at and
               migrated.updated_at == original.updated_at
           end)

    active = Enum.find(original_rows, &(&1.status == "active"))

    assert [["intents_one_active_per_ship_index"]] =
             Repo.query!(
               "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'intents_one_active_per_ship_index'"
             ).rows

    assert_raise Ecto.ConstraintError, ~r/intents_(one_active_per_ship|ship_id)_index/, fn ->
      %Intent{ship_id: active.ship_id}
      |> Intent.changeset(%{
        caller: "manual",
        type: "navigate",
        target_waypoint: active.target_waypoint,
        status: "active"
      })
      |> Repo.insert!()
    end
  end
end
