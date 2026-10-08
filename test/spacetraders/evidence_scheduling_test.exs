defmodule SpaceTraders.EvidenceSchedulingTest do
  # Clock configuration is application-wide, so these tests run synchronously.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Clock, Evidence, FleetStrategy, TestClock}
  alias SpaceTraders.Evidence.DemandScheduler

  @now ~U[2030-01-01 00:00:00.000000Z]
  @subject "market:X1-UX81:X1-UX81-A1"
  @demand %{
    subject: @subject,
    required_facts: ["trade_goods"],
    freshness_seconds: 300,
    owner: "fleet_planning"
  }

  setup_all do
    baseline = SpaceTraders.FixtureLeakProbe.baseline()
    on_exit(fn -> SpaceTraders.FixtureLeakProbe.assert_clean!(baseline) end)
  end

  setup do
    start_supervised!({TestClock, @now})
    previous_clock = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous_clock do
        Application.put_env(:spacetraders, :clock, previous_clock)
      else
        Application.delete_env(:spacetraders, :clock)
      end
    end)

    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "observation_demands")

    %{agent: agent, agent_id: agent.id, revision: revision}
  end

  test "a demand that becomes due during scheduler downtime is announced from persisted Evidence",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    due_at = DateTime.add(Clock.utc_now(), 60, :second)

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, Map.put(@demand, :due_at, due_at))

    assert Evidence.due_demands() == []

    scheduler =
      start_supervised!(Supervisor.child_spec({DemandScheduler, []}, restart: :temporary))

    monitor = Process.monitor(scheduler)
    Process.exit(scheduler, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^scheduler, :killed}, 1_000

    # Discard the clock's timers too: only PostgreSQL carries the requirement
    # across the missed due instant, and the fresh scheduler receives no demands.
    assert :ok = stop_supervised!(TestClock)
    start_supervised!({TestClock, DateTime.add(@now, 90, :second)})

    assert [persisted] = Evidence.due_demands()
    assert persisted.id == demand.id
    assert persisted.due_at == due_at

    start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [%{id: open_id}] = Evidence.list_open_demands(agent)
    assert open_id == demand.id
    assert {:error, :evidence_pending} = Evidence.evidence_for_demand(demand)
  end

  test "a fresh scheduler rearms a persisted future demand at its earliest useful time",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    due_at = DateTime.add(@now, 60, :second)

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, Map.put(@demand, :due_at, due_at))

    start_supervised!({DemandScheduler, []})

    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(TestClock)
    start_supervised!({TestClock, DateTime.add(@now, 30, :second)})

    assert Evidence.earliest_due_at() == due_at
    assert Evidence.due_demands() == []
    start_supervised!({DemandScheduler, []})

    TestClock.advance(29)
    refute_receive {:observation_demand_due, _, _}

    TestClock.advance(1)
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [%{id: due_id}] = Evidence.due_demands()
    assert due_id == demand.id
  end

  test "withdrawing the earliest requirement leaves the next durable demand scheduled",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    assert {:ok, first} =
             Evidence.request_demand(
               agent,
               revision,
               Map.put(@demand, :due_at, DateTime.add(@now, 30, :second))
             )

    second_subject = "market:X1-UX81:X1-UX81-A2"

    assert {:ok, second} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{
                 subject: second_subject,
                 due_at: DateTime.add(@now, 90, :second)
               })
             )

    start_supervised!({DemandScheduler, []})
    TestClock.advance(30)
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000

    assert {:ok, _withdrawn} = Evidence.withdraw_demand(first)
    assert Evidence.earliest_due_at() == second.due_at
    TestClock.advance(60)
    assert_receive {:observation_demand_due, ^agent_id, [^second_subject]}, 1_000
    assert [%{id: due_id}] = Evidence.due_demands()
    assert due_id == second.id
  end

  test "an open due requirement is announced again until authoritative Evidence fulfils it",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, Map.put(@demand, :due_at, @now))

    start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000

    TestClock.advance(30)
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [%{id: due_id}] = Evidence.due_demands()
    assert due_id == demand.id

    observation =
      Evidence.authoritative_observation(
        "get-market",
        [@subject],
        %{trade_goods: []},
        Clock.utc_now()
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, @subject, observation)

    assert fulfilled.id == demand.id
    assert Evidence.due_demands() == []
    assert Evidence.earliest_due_at() == nil

    TestClock.advance(30)
    refute_receive {:observation_demand_due, _, _}
  end

  # #589: an overdue demand nobody can acquire yet (no reachable Ship, spending
  # paused) was announced again on every unrelated demand change. Each
  # announcement woke reconciliation, whose owned reads changed demands again:
  # a read loop that bypassed the bounded retry interval.
  test "unrelated demand changes do not re-announce overdue work before its bounded retry",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    assert {:ok, _overdue} =
             Evidence.request_demand(agent, revision, Map.put(@demand, :due_at, @now))

    start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000

    Phoenix.PubSub.broadcast(
      SpaceTraders.PubSub,
      "observation_demands",
      {:observation_demands_changed, agent_id}
    )

    refute_receive {:observation_demand_due, _, _}, 200

    # Newly due work is still announced promptly, alongside the overdue work.
    other = "market:X1-UX81:X1-UX81-A2"

    assert {:ok, _new} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{subject: other, due_at: Clock.utc_now()})
             )

    assert_receive {:observation_demand_due, ^agent_id, subjects}, 1_000
    assert Enum.sort(subjects) == Enum.sort([@subject, other])

    TestClock.advance(30)
    assert_receive {:observation_demand_due, ^agent_id, [_, _]}, 1_000
  end

  # #589: an owned read persists its Observation Demand and acquires it itself.
  # Scheduling it announced in-flight Agent/Fleet reads as new due work, which
  # woke reconciliation into the same reads again: a Neutral Wait read loop.
  test "an owned read's own Observation Demand is not scheduled while its read is in flight",
       %{agent: agent} do
    test_pid = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      send(test_pid, {:during_read, Evidence.due_demands(), Evidence.earliest_due_at()})

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => agent.symbol,
          "credits" => 175_000,
          "headquarters" => "X1-UX81-A1",
          "startingFaction" => "COSMIC",
          "shipCount" => 1
        }
      })
    end)

    assert {:ok, _agent} = Evidence.get_agent(agent)
    # Only a bounded retry wake past the in-flight window is armed.
    assert_received {:during_read, [], ~U[2030-01-01 00:01:00.000000Z]}
  end

  # The in-flight exclusion is bounded: an owned read that failed leaves its
  # demand open, and that overdue demand must still be scheduled for retry.
  test "an owned read's unsettled Observation Demand stays overdue and is scheduled after its read",
       %{agent: agent} do
    Req.Test.stub(SpaceTraders.API, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

    assert {:error, _} = Evidence.get_agent_binding(agent)
    subject = "agent:#{agent.symbol}"
    assert Evidence.due_demands() == []
    assert DateTime.compare(Evidence.earliest_due_at(), @now) == :gt

    TestClock.advance(61)
    assert [%{subject: ^subject}] = Evidence.due_demands()
  end

  test "replacing a requirement moves its useful time without an early announcement",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    assert {:ok, original} =
             Evidence.request_demand(
               agent,
               revision,
               Map.put(@demand, :due_at, DateTime.add(@now, 60, :second))
             )

    start_supervised!({DemandScheduler, []})

    assert {:ok, replacement} =
             Evidence.replace_demand(original, %{due_at: DateTime.add(@now, 120, :second)})

    assert replacement.replaces_id == original.id
    assert Evidence.earliest_due_at() == replacement.due_at

    TestClock.advance(60)
    assert Evidence.due_demands() == []
    refute_receive {:observation_demand_due, _, _}

    TestClock.advance(60)
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [%{id: due_id}] = Evidence.due_demands()
    assert due_id == replacement.id
    refute_receive {:observation_demand_due, ^agent_id, [@subject]}
  end

  test "a deadline missed during downtime is recorded while its demand remains open",
       %{agent: agent, agent_id: agent_id, revision: revision} do
    assert {:ok, demand} =
             Evidence.request_demand(
               agent,
               revision,
               Map.merge(@demand, %{due_at: @now, deadline_at: DateTime.add(@now, 30, :second)})
             )

    scheduler = start_supervised!({DemandScheduler, []})
    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [%{deadline_missed_at: nil}] = Evidence.list_open_demands(agent)

    # The due broadcast happens before wake_due/1 finishes rearming from durable
    # Evidence. Wait for that callback to finish before simulating downtime so
    # we never kill a scheduler while it is using the shared Sandbox connection.
    _state = :sys.get_state(scheduler)
    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(TestClock)
    start_supervised!({TestClock, DateTime.add(@now, 60, :second)})
    start_supervised!({DemandScheduler, []})

    assert_receive {:observation_demand_due, ^agent_id, [@subject]}, 1_000
    assert [persisted] = Evidence.list_open_demands(agent)
    assert persisted.id == demand.id
    assert persisted.deadline_missed_at == Clock.utc_now()
    assert {:error, :evidence_pending} = Evidence.evidence_for_demand(demand)
  end
end
