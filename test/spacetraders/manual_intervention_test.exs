defmodule SpaceTraders.ManualInterventionTest do
  # Intervention recovery owns the shared ShipServer lifecycle.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.API.Model
  alias SpaceTraders.Fleet
  alias SpaceTraders.Fleet.{Intent, Intents, ShipServer}
  alias SpaceTraders.Timeline
  alias SpaceTraders.{ManualIntervention, MutationAttempts, Repo, ShipReservation}

  test "an exceptional Navigate mutation records its Intent and rejects overlapping intervention" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    symbol = "#{agent.symbol}-1"
    {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)
    activate_generation(scope, agent)
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

  test "an intervention-owned Navigate Intent completes exactly once after restart rearming" do
    on_exit(fn -> ShipServer.stop_all() end)

    operator = operator_fixture()
    agent = agent_fixture(operator)
    symbol = "#{agent.symbol}-1"
    {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")
    scope = Scope.for_operator(operator)
    activate_generation(scope, agent)
    assert {:ok, _reservation} = ShipReservation.reserve(scope, ship.id, "Recovery")

    ship_path = "/v2/my/ships/#{symbol}"
    navigate_path = "#{ship_path}/navigate"
    orbit_path = "#{ship_path}/orbit"
    {:ok, calls} = Elixir.Agent.start_link(fn -> %{phase: :initial, mutations: 0} end)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      state = Elixir.Agent.get(calls, & &1)

      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          nav =
            if state.phase == :initial,
              do: nav_body("DOCKED"),
              else: nav_body("IN_ORBIT", destination: "X1-UX81-A2")

          Req.Test.json(conn, %{"data" => ship_body(symbol, %{"nav" => nav})})

        {"POST", ^orbit_path} ->
          if state.phase != :initial, do: flunk("replayed intervention orbit")
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        {"POST", ^navigate_path} ->
          if state.phase != :initial, do: flunk("replayed intervention navigation")
          Elixir.Agent.update(calls, &%{&1 | mutations: &1.mutations + 1})

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

        request ->
          flunk("unexpected request: #{inspect(request)}")
      end
    end)

    assert {:ok, %Intent{caller: "intervention", status: "waiting"} = intent} =
             Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A2", "Correct course")

    assert Elixir.Agent.get(calls, & &1.mutations) == 1
    Elixir.Agent.update(calls, &%{&1 | phase: :restart, mutations: 0})
    ShipServer.stop(symbol)

    handler_id = "intervention-restart-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:spacetraders, :repo, :query],
        &__MODULE__.capture_query/4,
        self()
      )

    assert [symbol] == Intents.rearm_owned_intents_on_boot()

    live_ship =
      ship_body(symbol, %{"nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A2")})
      |> Model.Ship.from_json()

    assert {:ok, %Intent{status: "completed"}} =
             Intents.reconcile(agent.id, symbol, live_ship, :arrival, intent.id)

    :ok = :telemetry.detach(handler_id)

    assert Elixir.Agent.get(calls, & &1.mutations) == 0
    assert Repo.aggregate(Intent, :count) == 1
    assert %Intent{status: "completed"} = Repo.get!(Intent, intent.id)

    {:messages, messages} = Process.info(self(), :messages)

    refute Enum.any?(messages, fn
             {:repo_query, query} -> String.contains?(query, ~s("jobs"))
             _ -> false
           end)

    assert [%ManualIntervention{intent_id: intent_id}] = ManualIntervention.list(scope)
    assert intent_id == intent.id
    assert :ok = ShipReservation.release(scope, ship.id)
    assert ShipReservation.list(scope) == []

    Repo.delete!(intent)

    assert [%ManualIntervention{intent_id: nil, final_status: "completed"}] =
             ManualIntervention.list(scope)
  end

  for trigger <- [:boot, :arrival] do
    test "#{trigger} recovers a lost intervention Navigate response from retained evidence without replay" do
      on_exit(fn -> ShipServer.stop_all() end)

      operator = operator_fixture()
      agent = agent_fixture(operator)
      symbol = "#{agent.symbol}-1"
      {:ok, ship} = Fleet.record_ship(agent, symbol, "SHIP_COMMAND_FRIGATE")
      scope = Scope.for_operator(operator)
      activate_generation(scope, agent)
      assert {:ok, _reservation} = ShipReservation.reserve(scope, ship.id, "Recovery")

      ship_path = "/v2/my/ships/#{symbol}"
      in_transit = nav_body("IN_TRANSIT", arrival: future_arrival(), destination: "X1-UX81-A2")
      game = start_supervised!({Elixir.Agent, fn -> %{nav: nav_body("DOCKED"), posts: []} end})

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", ^ship_path} ->
            nav = Elixir.Agent.get(game, & &1.nav)
            Req.Test.json(conn, %{"data" => ship_body(symbol, %{"nav" => nav})})

          {"POST", path} ->
            kind = Path.basename(path)
            Elixir.Agent.update(game, &%{&1 | posts: &1.posts ++ [kind]})

            case kind do
              "orbit" ->
                Elixir.Agent.update(game, &%{&1 | nav: nav_body("IN_ORBIT")})
                Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

              "navigate" ->
                # The game accepts the request, but its response never arrives.
                Elixir.Agent.update(game, &%{&1 | nav: in_transit})
                Req.Test.transport_error(conn, :timeout)
            end
        end
      end)

      _ = Intents.intervene_navigate(scope, agent, symbol, "X1-UX81-A2", "Correct course")

      assert Elixir.Agent.get(game, & &1.posts) == ["orbit", "navigate"]
      assert [%ManualIntervention{intent_id: intent_id}] = ManualIntervention.list(scope)
      selected = Repo.get!(Intent, intent_id)
      assert selected.in_flight_action["kind"] == "navigate"
      lost = MutationAttempts.get!(selected.mutation_attempt_id)
      assert lost.state in ["sent_or_unknown", "ambiguous"]
      assert SpaceTraders.SafetyFence.active?(lost)

      ShipServer.stop(symbol)
      _ = Intents.reconcile(agent.id, symbol, nil, unquote(trigger), intent_id)

      assert Elixir.Agent.get(game, & &1.posts) == ["orbit", "navigate"]
      recovered = MutationAttempts.get!(lost.id)
      assert recovered.state == "accepted"
      refute SpaceTraders.SafetyFence.active?(recovered)

      assert [%{"source" => %{"id" => _source_id}}] =
               List.last(recovered.outcomes).evidence["observations"]

      assert %Intent{status: "waiting", in_flight_action: nil} = Repo.get!(Intent, intent_id)
      assert length(MutationAttempts.list_for_agent(agent)) == 2
      assert [%ManualIntervention{intent_id: ^intent_id}] = ManualIntervention.list(scope)
    end
  end

  defp future_arrival,
    do: DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()

  defp activate_generation(scope, agent) do
    {:ok, strategy} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = SpaceTraders.FleetStrategy.activate(scope, strategy.draft_version)

    Repo.insert!(%SpaceTraders.FleetGeneration.Generation{
      operator_id: scope.operator.id,
      agent_id: agent.id,
      fleet_strategy_revision_id: revision.id,
      number: 1,
      symbol: agent.symbol,
      faction: agent.faction
    })
  end

  def capture_query(_event, _measurements, metadata, test_pid),
    do: send(test_pid, {:repo_query, metadata.query})
end
