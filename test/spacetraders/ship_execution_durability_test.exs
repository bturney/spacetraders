defmodule SpaceTraders.ShipExecutionDurabilityTest do
  @moduledoc """
  First dispatch at the Ship Execution seam: a claimed root Intent, a controlled
  SpaceTraders boundary, and independently committed PostgreSQL evidence.
  """

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
  alias SpaceTraders.SafetyFence

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

    Process.exit(sender, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^sender, :killed}

    assert [^attempt] = attempts(agent)
    assert Repo.get!(Intent, intent.id) == intent
    assert Elixir.Agent.get(game, & &1) == "IN_ORBIT"
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
        {Elixir.Agent,
         fn -> %{mode: :initial, posture: "DOCKED", orbits: 0, navigations: 0} end}
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

  defp attempts(agent) do
    Repo.all(from a in Attempt, where: a.agent_id == ^agent.id, order_by: a.prepared_at)
  end

  defp restart_capacity_governor do
    :ok = Supervisor.terminate_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    {:ok, _pid} =
      Supervisor.restart_child(SpaceTraders.Supervisor, SpaceTraders.API.CapacityGovernor)

    :ok
  end

  defp claimed_ship do
    unique = System.unique_integer([:positive])
    operator = operator_fixture()
    agent = agent_fixture(operator, %{symbol: "DISPATCH#{unique}", agent_token: "TOKEN#{unique}"})

    ship =
      Repo.insert!(%Ship{
        agent_id: agent.id,
        symbol: "#{agent.symbol}-1",
        ship_type: "SHIP_PROBE"
      })

    on_exit(fn ->
      ShipServer.stop(ship.symbol)

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

    {:ok, selection} =
      FleetAllocation.select_portfolio(revision, [candidate], %{
        as_of: DateTime.utc_now(),
        source_version: generation.allocation_version,
        claims: [ship.symbol],
        reservations: %{}
      })

    {:ok, portfolio} =
      FleetAllocation.publish_portfolio(Scope.for_operator(operator), generation.id, selection, %{
        evidence_references: [],
        expectations: %{},
        calibration_version: "first-dispatch"
      })

    [commitment] = portfolio.commitments
    {agent, ship, portfolio, commitment}
  end
end
