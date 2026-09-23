defmodule SpaceTraders.LegacyAdmissionTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Job}
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.FleetStrategy
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Repo

  test "active Fleet Strategy rejects new legacy work but preserves existing history" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    {:ok, old_job} =
      %Job{ship_id: ship.id}
      |> Job.changeset(%{
        type: "miner",
        extraction_waypoint: "X1-A-A",
        market_waypoint: "X1-A-B",
        cargo_threshold: 10
      })
      |> Repo.insert()

    {:ok, old_intent} =
      %Intent{ship_id: ship.id}
      |> Intent.changeset(%{
        caller: "manual",
        type: "navigate",
        target_waypoint: "X1-A-B",
        status: "completed"
      })
      |> Repo.insert()

    Repo.insert!(%Strategy{operator_id: operator.id, active_revision_id: 1})

    assert Repo.get!(Job, old_job.id).type == "miner"
    assert Repo.get!(Intent, old_intent.id).caller == "manual"

    assert_raise Postgrex.Error, fn ->
      %Job{ship_id: ship.id}
      |> Job.changeset(%{
        type: "miner",
        extraction_waypoint: "X1-A-A",
        market_waypoint: "X1-A-B",
        cargo_threshold: 10
      })
      |> Repo.insert!()
    end
  end

  test "Strategy activation terminalizes unfinished legacy work without erasing its classification" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "survey",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "SURVEY-NONE",
        cargo_threshold: 1
      })

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        job_id: job.id,
        caller: "job",
        status: "active",
        type: "navigate",
        target_waypoint: "X1-UX81-A1"
      })

    assert {:ok, _} = FleetStrategy.select_preset(scope, "steady_growth")

    assert {:ok, _revision} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert %Job{type: "survey", status: "stopped", finished_at: %DateTime{}} =
             Repo.get!(Job, job.id)

    assert %Intent{caller: "job", status: "stopped", finished_at: %DateTime{}} =
             Repo.get!(Intent, intent.id)
  end

  test "activation waits for unresolved legacy mutation evidence instead of discarding it" do
    operator = operator_fixture()
    scope = Scope.for_operator(operator)
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    job =
      Repo.insert!(%Job{
        ship_id: ship.id,
        type: "survey",
        status: "active",
        extraction_waypoint: "X1-UX81-A1",
        market_waypoint: "SURVEY-NONE",
        cargo_threshold: 1,
        in_flight_action: %{"kind" => "survey"}
      })

    assert {:ok, _} = FleetStrategy.select_preset(scope, "steady_growth")

    assert {:error, :legacy_action_reconciliation_required} =
             FleetStrategy.activate(scope, FleetStrategy.get(scope).draft_version)

    assert Repo.get!(Job, job.id).status == "active"
    assert FleetStrategy.get(scope).active_revision == nil
  end

  test "a historical Intent cannot be relabelled as an autonomous caller" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "manual",
        status: "completed",
        target_waypoint: "X1-UX81-A2"
      })

    Repo.insert!(%Strategy{operator_id: operator.id, active_revision_id: 1})

    assert_raise Postgrex.Error, fn ->
      intent |> Ecto.Changeset.change(caller: "commitment") |> Repo.update!()
    end
  end

  test "database admission rejects a new old-style Intent after activation" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    {:ok, ship} = Fleet.record_ship(agent, "#{agent.symbol}-1", "SHIP_COMMAND_FRIGATE")
    Repo.insert!(%Strategy{operator_id: operator.id, active_revision_id: 1})

    assert_raise Postgrex.Error, fn ->
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "manual",
        status: "active",
        target_waypoint: "X1-UX81-A2"
      })
    end
  end
end
