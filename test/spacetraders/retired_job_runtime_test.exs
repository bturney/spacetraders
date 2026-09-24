defmodule SpaceTraders.RetiredJobRuntimeTest do
  use SpaceTraders.DataCase, async: false

  alias SpaceTraders.Agent.Agent, as: AgentRecord
  alias SpaceTraders.Agent.Operator
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Job, Ship}
  alias SpaceTraders.Fleet.Intents

  test "an Operator without a Strategy cannot configure, start, or resume a Job" do
    agent = agent_fixture()
    ship = ship_fixture(agent)

    assert {:error, :legacy_gameplay_retired} =
             Fleet.configure_miner_job(agent, ship.symbol, %{
               extraction_waypoint: "X1-UX81-A2",
               market_waypoint: "X1-UX81-A1",
               cargo_threshold: 20
             })

    job = job_fixture(ship)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("retired Job made a game request: #{conn.request_path}")
    end)

    assert {:error, :legacy_gameplay_retired} = Fleet.start_miner_job(agent, ship.symbol)
    assert {:error, :legacy_gameplay_retired} = Fleet.resume_miner_job(agent, ship.symbol)

    for start <- [
          &Fleet.start_survey_job/2,
          &Fleet.start_explorer_job/2,
          &Fleet.start_outfitting_job/2,
          &Fleet.start_procurement_job/2,
          &Fleet.start_construction_supply_job/2,
          &Fleet.start_market_trading_job/2,
          &Fleet.resume_market_trading_job/2,
          &Fleet.start_market_reconnaissance_job/2
        ] do
      assert {:error, :legacy_gameplay_retired} = start.(agent, ship.symbol)
    end

    assert {:error, :legacy_gameplay_retired} = Fleet.dock_ship(agent, ship.symbol)
    assert {:error, :legacy_gameplay_retired} = Fleet.extract_resources(agent, ship.symbol)

    assert {:error, :legacy_gameplay_retired} =
             Fleet.purchase_ship(%{agent: agent, shipyards: []}, "SHIP_PROBE", "X1-UX81-A1")

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        job_id: job.id,
        caller: "job",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting"
      })

    assert {:error, :legacy_gameplay_retired} =
             Intents.request(agent, %Intents.JobOwner{job: job}, ship.symbol, %Intents.Navigate{
               waypoint: "X1-UX81-A2"
             })

    assert {:error, :legacy_gameplay_retired} = Intents.advance(agent, intent, %{})

    historical_manual_intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "manual",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "completed"
      })

    scope = agent.operator_id |> then(&Repo.get!(Operator, &1)) |> Scope.for_operator()

    assert {:error, :legacy_gameplay_retired} =
             Intents.confirm(scope, %Intents.ManualControl{}, historical_manual_intent.id, 1)

    assert {:error, :legacy_gameplay_retired} = Fleet.recover_job_on_boot(ship.symbol, agent.id)

    assert {:error, :legacy_gameplay_retired} =
             Fleet.continue_job_event(agent.id, ship.symbol, %{}, :arrival, job.id)

    assert Repo.get!(Intent, intent.id).status == "waiting"
    assert Repo.get!(Job, job.id).status == "waiting"
  end

  test "direct Job continuation, replacement, and Intent insertion are retired" do
    agent = agent_fixture()
    ship = ship_fixture(agent)
    job = job_fixture(ship)

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        job_id: job.id,
        caller: "job",
        type: "navigate",
        target_waypoint: "X1-UX81-A2",
        status: "waiting"
      })

    Req.Test.stub(SpaceTraders.API, fn conn ->
      flunk("retired direct Job path made a game request: #{conn.request_path}")
    end)

    assert {:error, :legacy_gameplay_retired} = Fleet.replace_miner_job(agent, ship.symbol, %{})
    assert {:error, :legacy_gameplay_retired} = Fleet.reconcile_miner_job(agent, ship.symbol)
    assert {:error, :legacy_gameplay_retired} = Fleet.advance_miner_job(agent, job, %{})

    assert {:error, :legacy_gameplay_retired} =
             Fleet.advance_survey_job(agent, %{job | type: "survey"}, %{})

    assert {:error, :legacy_gameplay_retired} =
             Fleet.advance_explorer_job(agent, %{job | type: "explorer"}, %{})

    assert {:error, :legacy_gameplay_retired} =
             Fleet.continue_job_after_intent(agent, job, intent, %{})

    assert {:error, :legacy_gameplay_retired} = Intents.insert_job_intent(job, %{})
    assert Repo.get!(Intent, intent.id).status == "waiting"
  end

  test "historical Jobs remain readable" do
    agent = agent_fixture()
    ship = ship_fixture(agent)
    job = job_fixture(ship, status: "stopped", finished_at: DateTime.utc_now(:second))

    assert Fleet.ship_job(agent, ship.symbol) == nil
    assert [%Job{id: id, status: "stopped"}] = Fleet.ship_job_history(agent, ship.symbol)
    assert id == job.id
  end

  defp agent_fixture do
    operator =
      Repo.insert!(%Operator{email: "retired-#{System.unique_integer([:positive])}@example.com"})

    Repo.insert!(%AgentRecord{
      symbol: "RETIRED-#{System.unique_integer([:positive])}",
      faction: "COSMIC",
      headquarters: "X1-UX81-A1",
      agent_token: "AGENT_TOKEN",
      operator_id: operator.id
    })
  end

  defp ship_fixture(agent) do
    Repo.insert!(%Ship{symbol: "RETIRED-SHIP", ship_type: "SHIP_PROBE", agent_id: agent.id})
  end

  defp job_fixture(ship, attrs \\ []) do
    Repo.insert!(
      struct!(
        Job,
        Keyword.merge(
          [
            ship_id: ship.id,
            type: "miner",
            status: "waiting",
            extraction_waypoint: "X1-UX81-A2",
            market_waypoint: "X1-UX81-A1",
            cargo_threshold: 20
          ],
          attrs
        )
      )
    )
  end
end
