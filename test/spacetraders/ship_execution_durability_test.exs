defmodule SpaceTraders.ShipExecutionDurabilityTest do
  @moduledoc """
  First dispatch at the Ship Execution seam: a claimed root Intent, a controlled
  SpaceTraders boundary, and independently committed PostgreSQL evidence.
  """

  # These proofs switch SQL Sandbox mode and observe independently committed state.
  use ExUnit.Case, async: false

  import Ecto.Query
  import SpaceTraders.AgentFixtures
  import SpaceTraders.ShipBody

  alias Ecto.Adapters.SQL.Sandbox
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Fleet.{Intent, Intents, Ship, ShipServer}
  alias SpaceTraders.FleetAllocation
  alias SpaceTraders.FleetAllocation.PortfolioCandidate
  alias SpaceTraders.FleetGeneration.Generation
  alias SpaceTraders.FleetStrategy.{Revision, Strategy}
  alias SpaceTraders.MutationAttempts.{Attempt, Outcome}
  alias SpaceTraders.Repo
  alias SpaceTraders.RuntimeDeath
  alias SpaceTraders.SafetyFence
  alias SpaceTraders.Fleet.Intents.RecordedAction
  alias SpaceTraders.MutationAttempts

  setup do
    :ok = Sandbox.mode(Repo, :auto)
    :ok = Sandbox.checkout(Repo, sandbox: false)
    restart_capacity_governor()

    on_exit(fn ->
      # Sender death abandons its API admission; reset process-local capacity
      # after fixture teardown so later tests start with the full budget.
      restart_capacity_governor()
      SpaceTraders.EmergencyStopAdmission.clear()
      SpaceTraders.FleetGenerationAdmission.clear()
      :ok = Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "first accepted Ship mutation is independently visible and survives sender death" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    test_pid = self()
    game = start_supervised!({Elixir.Agent, fn -> "DOCKED" end})
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = ship_path <> "/orbit"

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "x" => 2,
              "y" => 2,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        {"POST", ^orbit_path} ->
          # The game accepts the effect, but never delivers its response. Pin the
          # sender's connection while the test observes through another backend.
          Elixir.Agent.update(game, fn _ -> "IN_ORBIT" end)

          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(test_pid, {:accepted, self(), backend, Repo.in_transaction?()})

            receive do
              :deliver_response ->
                Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
            after
              10_000 -> flunk("sender was not interrupted")
            end
          end)

        request ->
          flunk("unexpected Ship Execution request: #{inspect(request)}")
      end
    end)

    sender =
      start_supervised!(
        {Task,
         fn ->
           receive do
             :dispatch ->
               Intents.request_commitment_intelligence(
                 agent,
                 commitment,
                 portfolio,
                 ship.symbol,
                 %{
                   subject_type: :market,
                   waypoint: "X1-UX81-A2",
                   required_facts: ["trade_goods"],
                   freshness_seconds: 300
                 }
               )
           end
         end}
      )

    Req.Test.allow(SpaceTraders.API, self(), sender)
    monitor = Process.monitor(sender)
    send(sender, :dispatch)

    assert_receive {:accepted, ^sender, sender_backend, inside_transaction}, 5_000
    refute inside_transaction
    [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    assert observer_backend != sender_backend
    assert Elixir.Agent.get(game, & &1) == "IN_ORBIT"

    assert [%Attempt{state: "sent_or_unknown"} = attempt] = attempts(agent)
    assert %DateTime{} = attempt.sent_or_unknown_at
    assert is_nil(attempt.retry_of_id)
    assert %Intent{} = intent = Repo.get_by!(Intent, ship_id: ship.id)
    assert intent.mutation_attempt_id == attempt.id
    assert attempt.provenance["intent_id"] == intent.id

    assert attempt.provenance["selected_action_fingerprint"] ==
             SpaceTraders.Evidence.fingerprint(intent.in_flight_action)

    RuntimeDeath.kill(sender, sender_backend)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}

    assert [^attempt] = attempts(agent)
    assert Repo.get!(Intent, intent.id) == intent
    assert Elixir.Agent.get(game, & &1) == "IN_ORBIT"
  end

  test "boot after an accepted retry interruption resolves the committed effect without a second retry" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    Req.Test.set_req_test_to_shared(SpaceTraders.API)

    intent =
      Repo.insert!(%Intent{
        ship_id: ship.id,
        caller: "commitment",
        type: "navigate",
        target_waypoint: "X1-UX81-A1",
        fleet_commitment_id: commitment.id,
        fleet_commitment_portfolio_id: portfolio.id,
        fleet_commitment_portfolio_version: portfolio.version
      })

    {:ok, %{intent: intent, attempt: original}} =
      RecordedAction.prepare(agent, intent, %{
        "kind" => "orbit",
        "waypoint" => "X1-UX81-A1"
      })

    {:ok, original} = SpaceTraders.MutationAttempts.mark_sent_or_unknown(original)
    test_pid = self()
    game = start_supervised!({Elixir.Agent, fn -> %{status: "DOCKED", sends: 0} end})

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{
                "nav" => nav_body(Elixir.Agent.get(game, & &1.status))
              })
          })

        "POST" ->
          assert conn.request_path == "/v2/my/ships/#{ship.symbol}/orbit"
          Elixir.Agent.update(game, &%{status: "IN_ORBIT", sends: &1.sends + 1})

          Repo.checkout(fn ->
            [[backend]] = Repo.query!("SELECT pg_backend_pid()").rows
            send(test_pid, {:retry_accepted, self(), backend, Repo.in_transaction?()})

            receive do
              :deliver -> Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
            after
              10_000 -> flunk("accepted retry sender was not interrupted")
            end
          end)
      end
    end)

    sender =
      start_supervised!(
        {Task,
         fn ->
           Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)
         end}
      )

    monitor = Process.monitor(sender)
    assert_receive {:retry_accepted, ^sender, sender_backend, inside_transaction}, 5_000
    refute inside_transaction
    [[observer_backend]] = Repo.query!("SELECT pg_backend_pid()").rows
    refute sender_backend == observer_backend
    assert [absent, retry] = attempts(agent)
    assert absent.id == original.id
    assert absent.state == "absent"
    refute absent.retry_authorized
    assert retry.retry_of_id == original.id
    assert retry.state == "sent_or_unknown"
    assert %DateTime{} = retry.sent_or_unknown_at
    assert Repo.get!(Intent, intent.id).mutation_attempt_id == retry.id

    RuntimeDeath.kill(sender, sender_backend)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}
    assert [^absent, ^retry] = attempts(agent)
    restart_capacity_governor()
    assert :ok = Intents.rearm_on_boot()
    assert Repo.get!(Intent, intent.id).status == "completed"
    assert SpaceTraders.MutationAttempts.get!(retry.id).state == "accepted"
    refute SafetyFence.active?(SpaceTraders.MutationAttempts.get!(retry.id))
    assert length(attempts(agent)) == 2
    assert Elixir.Agent.get(game, & &1.sends) == 1
  end

  test "ambiguous Ship mutation stays fenced across sender death until authoritative recovery" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    Req.Test.set_req_test_to_shared(SpaceTraders.API)
    test_pid = self()
    ship_path = "/v2/my/ships/#{ship.symbol}"
    orbit_path = ship_path <> "/orbit"
    navigate_path = ship_path <> "/navigate"

    game =
      start_supervised!(
        {Elixir.Agent, fn -> %{mode: :initial, posture: "DOCKED", orbits: 0, navigations: 0} end}
      )

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^ship_path} ->
          case Elixir.Agent.get(game, & &1.mode) do
            :initial ->
              Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

            :unavailable ->
              Req.Test.transport_error(conn, :timeout)

            :authoritative ->
              Req.Test.json(conn, %{
                "data" =>
                  ship_body(ship.symbol, %{
                    "nav" => nav_body("IN_ORBIT", destination: "X1-UX81-A1")
                  })
              })
          end

        {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"} ->
          Req.Test.json(conn, %{
            "data" => %{
              "symbol" => "X1-UX81-A2",
              "systemSymbol" => "X1-UX81",
              "type" => "PLANET",
              "x" => 2,
              "y" => 2,
              "traits" => [%{"symbol" => "MARKETPLACE"}]
            }
          })

        {"POST", ^orbit_path} ->
          Elixir.Agent.update(game, fn state ->
            %{state | mode: :unavailable, posture: "IN_ORBIT", orbits: state.orbits + 1}
          end)

          send(test_pid, {:orbit_response_lost, self()})
          Req.Test.transport_error(conn, :timeout)

        {"POST", ^navigate_path} ->
          Elixir.Agent.update(game, fn state ->
            %{state | navigations: state.navigations + 1}
          end)

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
          flunk("unexpected Ship Execution request: #{inspect(request)}")
      end
    end)

    sender =
      start_supervised!(
        {Task,
         fn ->
           result =
             Intents.request_commitment_intelligence(
               agent,
               commitment,
               portfolio,
               ship.symbol,
               %{
                 subject_type: :market,
                 waypoint: "X1-UX81-A2",
                 required_facts: ["trade_goods"],
                 freshness_seconds: 300
               }
             )

           send(test_pid, {:lost_response_result, self(), result})

           receive do
             :stop -> :ok
           end
         end}
      )

    monitor = Process.monitor(sender)

    assert_receive {:orbit_response_lost, ^sender}, 5_000
    assert_receive {:lost_response_result, ^sender, _result}, 5_000

    assert [%Attempt{state: "ambiguous"} = attempt] = attempts(agent)
    attempt = SpaceTraders.MutationAttempts.get!(attempt.id)
    assert [%{classification: "ambiguous"}] = attempt.outcomes
    assert SafetyFence.active?(attempt)
    assert %Intent{status: "blocked"} = intent = Repo.get_by!(Intent, ship_id: ship.id)
    assert intent.mutation_attempt_id == attempt.id
    assert intent.in_flight_action["kind"] == "orbit"

    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}

    assert :ok = Intents.rearm_on_boot()

    preserved = SpaceTraders.MutationAttempts.get!(attempt.id)
    assert preserved.state == "ambiguous"
    assert SafetyFence.active?(preserved)
    assert Repo.get!(Intent, intent.id).in_flight_action["kind"] == "orbit"

    assert %{posture: "IN_ORBIT", orbits: 1, navigations: 0} =
             Elixir.Agent.get(game, &Map.take(&1, [:posture, :orbits, :navigations]))

    Elixir.Agent.update(game, &%{&1 | mode: :authoritative})
    _ = Intents.reconcile(agent.id, ship.symbol, nil, :boot, intent.id)

    reconciled = SpaceTraders.MutationAttempts.get!(attempt.id)
    assert reconciled.state == "accepted"
    refute SafetyFence.active?(reconciled)

    assert Enum.any?(
             attempts(agent),
             &(&1.operation_id == "navigate-ship" and &1.state == "succeeded")
           )

    assert %{orbits: 1, navigations: 1} =
             Elixir.Agent.get(game, &Map.take(&1, [:orbits, :navigations]))
  end

  for loss <- [
        :claim,
        :generation,
        :revision,
        :selection,
        :singleton,
        :intervention,
        :portfolio_version
      ] do
    @loss loss
    test "#{@loss} authority lost after preparation prevents Ship dispatch" do
      {agent, ship, portfolio, commitment} = claimed_ship()
      test_pid = self()
      ship_path = "/v2/my/ships/#{ship.symbol}"

      Req.Test.stub(SpaceTraders.API, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", ^ship_path} ->
            Req.Test.json(conn, %{"data" => ship_body(ship.symbol)})

          {"GET", "/v2/systems/X1-UX81/waypoints/X1-UX81-A2"} ->
            Req.Test.json(conn, %{
              "data" => %{
                "symbol" => "X1-UX81-A2",
                "systemSymbol" => "X1-UX81",
                "type" => "PLANET",
                "x" => 2,
                "y" => 2,
                "traits" => [%{"symbol" => "MARKETPLACE"}]
              }
            })

          {"POST", _path} ->
            flunk("Ship mutation dispatched after #{@loss} authority was lost")

          request ->
            flunk("unexpected Ship Execution request: #{inspect(request)}")
        end
      end)

      handler = "lost-authority-#{@loss}-#{System.unique_integer([:positive])}"

      :ok =
        :telemetry.attach(
          handler,
          [:spacetraders, :recorded_dispatch, :prepared],
          &pause_dispatch/4,
          test_pid
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      sender =
        start_supervised!(
          {Task,
           fn ->
             receive do
               :dispatch ->
                 result =
                   Intents.request_commitment_intelligence(
                     agent,
                     commitment,
                     portfolio,
                     ship.symbol,
                     %{
                       subject_type: :market,
                       waypoint: "X1-UX81-A2",
                       required_facts: ["trade_goods"],
                       freshness_seconds: 300
                     }
                   )

                 send(test_pid, {:dispatch_result, self(), result})
             end
           end}
        )

      Req.Test.allow(SpaceTraders.API, self(), sender)
      monitor = Process.monitor(sender)
      send(sender, :dispatch)
      assert_receive {:prepared_dispatch, ^sender, attempt_id}, 5_000

      revoke_authority(@loss, agent, Repo.get_by!(Intent, ship_id: ship.id))
      send(sender, :continue_dispatch)
      assert_receive {:dispatch_result, ^sender, _result}, 5_000
      assert_receive {:DOWN, ^monitor, :process, ^sender, :normal}, 5_000

      assert [%Attempt{state: "not_sent", sent_or_unknown_at: nil, id: ^attempt_id} = attempt] =
               attempts(agent)

      assert [%{classification: "not_sent"}] =
               SpaceTraders.MutationAttempts.get!(attempt.id).outcomes
    end
  end

  test "concurrent retry preparation and dispatch consume one permission and one transport effect" do
    {agent, ship, portfolio, commitment} = claimed_ship()
    intent = owned_navigation(ship, portfolio, commitment)

    {:ok, %{intent: intent, attempt: original}} =
      RecordedAction.prepare(agent, intent, %{"kind" => "orbit", "waypoint" => "X1-UX81-A1"})

    {:ok, original} = MutationAttempts.mark_sent_or_unknown(original)
    game = start_supervised!({Elixir.Agent, fn -> %{status: "DOCKED", sends: 0} end})
    Req.Test.set_req_test_to_shared(SpaceTraders.API)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.method do
        "GET" ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(ship.symbol, %{"nav" => nav_body(Elixir.Agent.get(game, & &1.status))})
          })

        "POST" ->
          assert conn.request_path == "/v2/my/ships/#{ship.symbol}/orbit"
          Elixir.Agent.update(game, &%{status: "IN_ORBIT", sends: &1.sends + 1})
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})
      end
    end)

    assert {:ok, binding} =
             SpaceTraders.Evidence.get_ship_binding(
               SpaceTraders.API.AgentTokenReference.new(agent),
               ship.symbol
             )

    {:ok, proof} =
      SpaceTraders.Evidence.recovery_proof(
        original,
        :absent,
        "Fresh governed observation proves the original orbit absent",
        [binding]
      )

    {:ok, absent} = MutationAttempts.reconcile(original, :absent, proof)

    results = concurrent(8, fn -> RecordedAction.prepare_retry(agent, intent, absent) end)
    assert [{:ok, retry}] = Enum.filter(results, &match?({:ok, _}, &1))
    assert Enum.count(results, &match?({:error, _}, &1)) == 7
    results = concurrent(8, fn -> SpaceTraders.API.dispatch_recorded(retry) end)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, _}, &1)) == 7
    assert Elixir.Agent.get(game, & &1.sends) == 1
    assert [original, retried] = MutationAttempts.list_for_agent(agent)
    refute original.retry_authorized
    assert retried.id == retry.id
    assert retried.retry_of_id == original.id
    assert retried.state == "succeeded"
    assert :ok = Intents.rearm_on_boot()
    assert :ok = Intents.rearm_on_boot()
    assert Elixir.Agent.get(game, & &1.sends) == 1
  end

  test "unresolved shared credits fence dependent spending while independently claimed Ship execution continues" do
    {agent, source, portfolio, commitment} = claimed_ship(3)

    [_, dependent, independent] =
      Repo.all(from s in Ship, where: s.agent_id == ^agent.id, order_by: s.symbol)

    source_intent = owned_navigation(source, portfolio, commitment)

    spending = %{
      "kind" => "buy",
      "waypoint" => "X1-UX81-A1",
      "trade_symbol" => "IRON_ORE",
      "units" => 5,
      "listing_price" => 10
    }

    {:ok, %{attempt: unknown}} = RecordedAction.prepare(agent, source_intent, spending)
    {:ok, unknown} = MutationAttempts.mark_sent_or_unknown(unknown)

    assert Enum.sort(unknown.dependency_keys) ==
             Enum.sort(["ship:#{agent.id}:#{source.symbol}", "agent_credits:#{agent.id}"])

    dependent_commitment = Enum.find(portfolio.commitments, &(dependent.symbol in &1.claims))
    dependent_intent = owned_navigation(dependent, portfolio, dependent_commitment)

    assert {:error, {:safety_fenced, [blocked]}} =
             RecordedAction.prepare(agent, dependent_intent, spending)

    assert blocked == unknown.id
    assert Repo.get!(Intent, dependent_intent.id).in_flight_action == nil

    independent_commitment = Enum.find(portfolio.commitments, &(independent.symbol in &1.claims))
    independent_intent = owned_navigation(independent, portfolio, independent_commitment)

    {:ok, _} =
      RecordedAction.prepare(agent, independent_intent, %{
        "kind" => "orbit",
        "waypoint" => "X1-UX81-A1"
      })

    independent_path = "/v2/my/ships/#{independent.symbol}"
    orbit_path = independent_path <> "/orbit"
    game = start_supervised!({Elixir.Agent, fn -> %{status: "DOCKED", sends: []} end})
    Req.Test.set_req_test_to_shared(SpaceTraders.API)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", ^independent_path} ->
          Req.Test.json(conn, %{
            "data" =>
              ship_body(independent.symbol, %{
                "nav" => nav_body(Elixir.Agent.get(game, & &1.status))
              })
          })

        {"POST", ^orbit_path} ->
          Elixir.Agent.update(game, &%{status: "IN_ORBIT", sends: &1.sends ++ [orbit_path]})
          Req.Test.json(conn, %{"data" => %{"nav" => nav_body("IN_ORBIT")}})

        request ->
          flunk("fenced dependent reached transport: #{inspect(request)}")
      end
    end)

    _ = Intents.reconcile(agent.id, independent.symbol, nil, :boot, independent_intent.id)

    assert Elixir.Agent.get(game, & &1.sends) == ["/v2/my/ships/#{independent.symbol}/orbit"]
    assert MutationAttempts.get!(unknown.id).state == "sent_or_unknown"
    assert SafetyFence.active?(MutationAttempts.get!(unknown.id))
    assert [%{id: ^blocked}] = SafetyFence.blocking_attempts(["agent_credits:#{agent.id}"])
    assert SafetyFence.blocking_attempts(["ship:#{agent.id}:#{independent.symbol}"]) == []
  end

  defp concurrent(count, fun) do
    tasks =
      for _ <- 1..count,
          do:
            Task.async(fn ->
              receive do
                :go -> fun.()
              end
            end)

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await(&1, 5_000))
  end

  defp owned_navigation(ship, portfolio, commitment) do
    Repo.insert!(%Intent{
      ship_id: ship.id,
      caller: "commitment",
      type: "navigate",
      status: "active",
      target_waypoint: "X1-UX81-A1",
      fleet_commitment_id: commitment.id,
      fleet_commitment_portfolio_id: portfolio.id,
      fleet_commitment_portfolio_version: portfolio.version
    })
  end

  defp pause_dispatch(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:prepared_dispatch, self(), metadata.attempt_id})

    receive do
      :continue_dispatch -> :ok
    after
      10_000 -> flunk("prepared Ship dispatch was not released")
    end
  end

  defp revoke_authority(:claim, _agent, intent) do
    Repo.get!(SpaceTraders.FleetAllocation.Portfolio, intent.fleet_commitment_portfolio_id)
    |> Ecto.Changeset.change(superseded_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke_authority(:generation, agent, _intent) do
    Repo.get_by!(Generation, agent_id: agent.id)
    |> Ecto.Changeset.change(fenced_at: DateTime.utc_now())
    |> Repo.update!()
  end

  defp revoke_authority(:revision, agent, _intent) do
    scope = Scope.for_operator(Repo.get!(SpaceTraders.Agent.Operator, agent.operator_id))
    {:ok, strategy} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    assert {:ok, _revision} = SpaceTraders.FleetStrategy.activate(scope, strategy.draft_version)
  end

  defp revoke_authority(:selection, _agent, intent) do
    intent |> Ecto.Changeset.change(in_flight_action: nil) |> Repo.update!()
  end

  defp revoke_authority(:singleton, _agent, _intent) do
    previous = Application.get_env(:spacetraders, SpaceTraders.RuntimeAuthority)
    Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, enabled: true)
    on_exit(fn -> Application.put_env(:spacetraders, SpaceTraders.RuntimeAuthority, previous) end)

    assert {:error, :runtime_authority_unavailable} =
             SpaceTraders.RuntimeAuthority.execution_allowed?()
  end

  defp revoke_authority(:intervention, _agent, intent) do
    intent
    |> Ecto.Changeset.change(
      caller: "intervention",
      fleet_commitment_id: nil,
      fleet_commitment_portfolio_id: nil,
      fleet_commitment_portfolio_version: nil
    )
    |> Repo.update!()
  end

  defp revoke_authority(:portfolio_version, _agent, intent) do
    intent
    |> Ecto.Changeset.change(
      fleet_commitment_portfolio_version: intent.fleet_commitment_portfolio_version + 1
    )
    |> Repo.update!()
  end

  defp attempts(agent) do
    Repo.all(from a in Attempt, where: a.agent_id == ^agent.id, order_by: a.prepared_at)
  end

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    :ok
  end

  defp claimed_ship(count \\ 1) do
    unique = System.unique_integer([:positive])
    operator = operator_fixture()
    agent = agent_fixture(operator, %{symbol: "DISPATCH#{unique}", agent_token: "TOKEN#{unique}"})

    ship =
      Repo.insert!(%Ship{
        agent_id: agent.id,
        symbol: "#{agent.symbol}-1",
        ship_type: "SHIP_PROBE"
      })

    ships = [
      ship
      | for(
          n <- 2..count//1,
          do:
            Repo.insert!(%Ship{
              agent_id: agent.id,
              symbol: "#{agent.symbol}-#{n}",
              ship_type: "SHIP_PROBE"
            })
        )
    ]

    on_exit(fn ->
      ShipServer.stop(ship.symbol)
      Enum.each(ships, &ShipServer.stop(&1.symbol))

      Sandbox.unboxed_run(Repo, fn ->
        attempt_ids = Repo.all(from a in Attempt, where: a.agent_id == ^agent.id, select: a.id)
        Repo.delete_all(from o in Outcome, where: o.mutation_attempt_id in ^attempt_ids)
        Repo.delete_all(from a in Attempt, where: a.id in ^attempt_ids)

        Repo.delete_all(
          from d in SpaceTraders.Evidence.ObservationDemand, where: d.agent_id == ^agent.id
        )

        Repo.delete_all(
          from o in SpaceTraders.Evidence.Observation, where: o.agent_id == ^agent.id
        )

        topics = ["fleet:#{agent.id}", "fleet_allocation:#{operator.id}"]
        Repo.delete_all(from n in SpaceTraders.Outbox.Notification, where: n.topic in ^topics)
        Repo.delete_all(from e in SpaceTraders.Timeline.Event, where: e.owner_id == ^ship.symbol)
        Repo.delete!(operator)
      end)
    end)

    strategy = Repo.insert!(%Strategy{operator_id: operator.id, revision_number: 1})

    revision =
      Repo.insert!(%Revision{
        fleet_strategy_id: strategy.id,
        number: 1,
        document: %{"objectives" => [%{"objective" => "Grow credits"}], "hard_constraints" => []},
        source: "operator",
        activated_at: DateTime.utc_now(:second)
      })

    Repo.update!(Ecto.Changeset.change(strategy, active_revision_id: revision.id))

    generation =
      Repo.insert!(%Generation{
        operator_id: operator.id,
        agent_id: agent.id,
        fleet_strategy_revision_id: revision.id,
        number: 1,
        symbol: agent.symbol,
        faction: agent.faction
      })

    candidate = %PortfolioCandidate{
      id: "first-dispatch",
      strategy_revision_id: revision.id,
      objective_index: 0,
      claims: [ship.symbol],
      reservations: %{},
      pledges: [],
      dependencies: [],
      expected_value: 1,
      unwind_cost: 0
    }

    candidates =
      Enum.map(ships, fn s -> %{candidate | id: "dispatch-#{s.symbol}", claims: [s.symbol]} end)

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, candidates, %{
        as_of: DateTime.utc_now(),
        source_version: generation.allocation_version,
        claims: Enum.map(ships, & &1.symbol),
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "first-dispatch"
      })

    commitment = Enum.find(portfolio.commitments, &(ship.symbol in &1.claims))
    {agent, ship, portfolio, commitment}
  end
end
