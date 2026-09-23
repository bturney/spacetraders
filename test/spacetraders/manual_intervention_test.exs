defmodule SpaceTraders.ManualInterventionTest do
  use SpaceTraders.DataCase

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Intents, ShipServer}
  alias SpaceTraders.FleetStrategy.Strategy
  alias SpaceTraders.Timeline
  alias SpaceTraders.{ManualIntervention, Repo, ShipReservation}

  test "a reserved Ship receives one authenticated, durable intervention instead of Manual Control" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    symbol = "#{agent.symbol}-1"
    {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)
    Repo.insert!(%Strategy{operator_id: operator.id, active_revision_id: 1})

    assert {:error, :legacy_gameplay_retired} =
             Intents.request(scope, agent, %Intents.ManualControl{}, symbol, %Intents.Navigate{
               waypoint: "X1-UX81-A1"
             })

    assert {:error, :ship_not_reserved} =
             Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A1", "Recover route")

    assert {:ok, _reservation} = ShipReservation.reserve(scope, ship.id, "Operator recovery")

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {"/v2/my/ships/#{symbol}", "GET"} == {conn.request_path, conn.method}
      Req.Test.json(conn, %{"data" => ship_body(symbol)})
    end)

    assert {:ok, %Intent{caller: "intervention"} = intent} =
             Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A1", "Recover route")

    assert [%ManualIntervention{intent_id: intent_id, reason: "Recover route"}] =
             ManualIntervention.list(scope)

    assert intent_id == intent.id
    assert intent.status == "completed"
    assert :ok = ShipReservation.release(scope, ship.id)
    assert ShipReservation.reserved_symbols(agent.id) == []

    assert {:error, :ship_not_reserved} =
             Intents.intervene_navigate(
               scope,
               agent,
               symbol,
               "X1-UX81-A2",
               "Try released authority"
             )

    Repo.delete!(Repo.get!(Intent, intent.id))

    assert [
             %ManualIntervention{
               intent_id: nil,
               final_status: "completed",
               target_waypoint: "X1-UX81-A1"
             }
           ] = ManualIntervention.list(scope)
  end

  test "an exceptional Navigate mutation records its Intent and rejects overlapping intervention" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    symbol = "#{agent.symbol}-1"
    {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)
    Repo.insert!(%Strategy{operator_id: operator.id, active_revision_id: 1})
    assert {:ok, _} = ShipReservation.reserve(scope, ship.id, "Recovery")
    ship_path = "/v2/my/ships/#{symbol}"
    navigate_path = "#{ship_path}/navigate"
    orbit_path = "#{ship_path}/orbit"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.request_path, conn.method} do
        {^ship_path, "GET"} ->
          Req.Test.json(conn, %{"data" => ship_body(symbol)})

        {^orbit_path, "POST"} ->
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {^navigate_path, "POST"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "fuel" => %{"capacity" => 200, "current" => 80},
              "nav" =>
                nav_body("IN_TRANSIT",
                  arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                  destination: "X1-UX81-A2"
                )
            }
          })
      end
    end)

    assert {:ok, %Intent{caller: "intervention", status: "waiting"} = intent} =
             Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A2", "Correct course")

    assert ManualIntervention.list(scope) |> hd() |> Map.get(:intent_id) == intent.id

    assert {:error, :ship_busy} =
             Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A3", "Second course")

    assert {:error, :intervention_in_progress} = ShipReservation.release(scope, ship.id)

    ShipServer.stop(symbol)

    for event <- Timeline.pending_events(:ship, symbol), do: Timeline.fire_event(event)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert {^ship_path, "GET"} = {conn.request_path, conn.method}

      Req.Test.json(conn, %{
        "data" =>
          ship_body(symbol, %{
            "nav" =>
              nav_body("IN_TRANSIT",
                arrival: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601(),
                destination: "X1-UX81-A2"
              )
          })
      })
    end)

    handler_id = "intervention-boot-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:spacetraders, :repo, :query],
        &__MODULE__.capture_query/4,
        self()
      )

    assert [symbol] == Intents.rearm_owned_intents_on_boot()
    :ok = :telemetry.detach(handler_id)

    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:repo_query, query} -> String.contains?(query, ~s("jobs"))
             _ -> false
           end)

    assert :ok = Intents.rearm_on_boot()

    assert Repo.get!(Intent, intent.id).status == "waiting"
    assert symbol in ShipReservation.reserved_symbols(agent.id)

    assert [%ManualIntervention{intent_id: recovered_id, reason: "Correct course"}] =
             ManualIntervention.list(scope)

    assert recovered_id == intent.id
  end

  def capture_query(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:repo_query, metadata.query})
end
