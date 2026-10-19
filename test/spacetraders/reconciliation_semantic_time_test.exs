defmodule SpaceTraders.ReconciliationSemanticTimeTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Clock, Evidence, FleetGeneration, FleetStrategy, Quiesced, TestClock}
  alias SpaceTraders.FleetAllocation.Reconciler

  @now ~U[2000-01-01 00:00:00.000000Z]

  setup do
    start_supervised!({TestClock, @now})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, preset} = FleetStrategy.select_preset(scope, "steady_growth")
    document = put_in(preset.draft, ["objectives", Access.at(0), "objective"], "Fulfil contracts")
    {:ok, draft} = FleetStrategy.save_draft(scope, document, preset.draft_version)
    {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)
    {:ok, %{generation: generation}} = FleetGeneration.current_fleet()
    owner = self()

    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/contracts" ->
          send(owner, {:contracts_read, Clock.utc_now()})
          Req.Test.json(conn, %{"data" => []})

        "/v2/my/ships" ->
          Req.Test.json(conn, %{"data" => []})

        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 175_000}})

        path ->
          flunk("unexpected gameplay request: #{path}")
      end
    end)

    %{agent: agent, scope: scope, generation: generation, revision: revision}
  end

  test "scheduler and participant recover an overdue demand under the current Revision",
       %{agent: agent, scope: scope, generation: generation, revision: revision} do
    alias SpaceTraders.Evidence.DemandScheduler

    start_reconciler()
    flush_contract_reads()
    subject = "contracts:#{agent.symbol}"
    {:ok, demand} = Evidence.request_demand(agent, revision, %{
      subject: subject, required_facts: ["response"], freshness_seconds: 30,
      owner: "fleet_planning", due_at: DateTime.add(@now, 30), deadline_at: DateTime.add(@now, 45)
    })

    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "observation_demands")
    start_supervised!(Quiesced.child_spec({DemandScheduler, []}))
    # Owned Contract reads keep their existing 60-second in-flight allowance.
    assert Evidence.earliest_due_at() == ~U[2000-01-01 00:01:30.000000Z]
    assert TestClock.next_due_at() == ~U[2000-01-01 00:01:00.000000Z]
    TestClock.advance(29)
    barrier()
    refute_receive {:contracts_read, _}

    assert :ok = stop_supervised!(Reconciler)
    assert :ok = stop_supervised!(DemandScheduler)
    assert :ok = stop_supervised!(TestClock)
    start_supervised!({TestClock, ~U[2000-01-01 00:02:01.000000Z]})

    # Activation remains the normal immutable-Revision boundary while owners
    # are down. Reconstructed work must not revive the previous authority.
    projection = FleetStrategy.get(scope)
    document = Map.put(projection.draft, "consequences", "Revised Contract authority.")
    {:ok, draft} = FleetStrategy.save_draft(scope, document, projection.draft_version)
    {:ok, active} = FleetStrategy.activate(scope, draft.draft_version)
    assert active.id != revision.id

    start_supervised!(Quiesced.child_spec({DemandScheduler, []}))
    GenServer.call(DemandScheduler, :simulation_barrier)
    assert_receive {:observation_demand_due, agent_id, subjects}
    assert agent_id == agent.id
    assert subject in subjects
    assert [%{id: demand_id, deadline_missed_at: missed}] = Evidence.list_open_demands(agent)
    assert demand_id == demand.id
    assert missed == ~U[2000-01-01 00:02:01.000000Z]

    start_reconciler()
    assert_receive {:contracts_read, ~U[2000-01-01 00:02:01.000000Z]}
    assert {:ok, source} = Evidence.evidence_for_demand(demand)
    assert source.observed_at == ~U[2000-01-01 00:02:01.000000Z]
    assert source.fleet_generation_id == generation.id
    assert {:ok, %{generation: current}} = FleetGeneration.current_fleet()
    assert current.id == generation.id
    assert current.fleet_strategy_revision_id == active.id
    assert current.initial_fleet_strategy_revision_id == generation.initial_fleet_strategy_revision_id
    GenServer.call(DemandScheduler, :simulation_barrier)
    assert Evidence.due_demands() == []
    assert TestClock.next_due_at() == ~U[2000-01-01 00:03:01.000000Z]
  end

  test "fresh Contract acceptance evidence uses gameplay time without relaxing the credit floor",
       %{agent: agent, revision: revision} do
    Req.Test.stub(SpaceTraders.API, fn conn ->
      case conn.request_path do
        "/v2/my/contracts" ->
          Req.Test.json(conn, %{"data" => [%{
            "id" => "offered", "accepted" => false, "fulfilled" => false,
            "deadlineToAccept" => "2000-01-01T01:00:00Z",
            "terms" => %{"deadline" => "2000-01-02T00:00:00Z", "deliver" => [],
              "payment" => %{"onAccepted" => 0, "onFulfilled" => 1000}}
          }]})

        "/v2/my/agent" ->
          Req.Test.json(conn, %{"data" => %{"symbol" => agent.symbol, "credits" => 175_000}})

        path -> flunk("inadmissible acceptance sent a mutation: #{path}")
      end
    end)

    evidence = %{as_of: @now, worst_case_cost: 200_000, estimated_seconds: 60, evidence_id: "offer"}
    assert {:error, :hard_constraint} =
             SpaceTraders.FleetContracts.accept_if_admissible(agent, revision, "offered", evidence)

    TestClock.advance(301)
    assert {:error, :stale_acceptance_evidence} =
             SpaceTraders.FleetContracts.accept_if_admissible(agent, revision, "offered", evidence)
  end

  test "participant reconstructs reconciliation after restart and rejects obsolete refresh wakes",
       %{agent: agent, generation: generation, revision: revision} do
    start_reconciler()
    assert_receive {:contracts_read, @now}
    flush_contract_reads()

    TestClock.advance(59)
    barrier()
    refute_receive {:contracts_read, _}

    TestClock.advance(1)
    barrier()
    assert_receive {:contracts_read, ~U[2000-01-01 00:01:00.000000Z]}

    # A refresh delivered twice must not perform another acquisition or fork
    # the recurring timer chain. This is the old untagged timer message.
    send(Process.whereis(Reconciler), :reconcile_durable_work)
    barrier()
    refute_receive {:contracts_read, _}
    assert TestClock.next_due_at() == ~U[2000-01-01 00:02:00.000000Z]

    assert :ok = stop_supervised!(Reconciler)
    assert :ok = stop_supervised!(TestClock)
    start_supervised!({TestClock, ~U[2000-01-01 00:03:00.000000Z]})
    start_reconciler()
    assert_receive {:contracts_read, ~U[2000-01-01 00:03:00.000000Z]}

    retained = Evidence.latest_observation(agent, "contracts:#{agent.symbol}")
    assert retained.observed_at == ~U[2000-01-01 00:03:00.000000Z]
    assert retained.fleet_generation_id == generation.id
    assert {:ok, %{generation: current}} = FleetGeneration.current_fleet()
    assert current.id == generation.id
    assert current.fleet_strategy_revision_id == revision.id
    assert TestClock.next_due_at() == ~U[2000-01-01 00:04:00.000000Z]
  end

  defp start_reconciler do
    start_supervised!(Quiesced.child_spec({Reconciler, []}))
    # Boot enqueues the normal Waypoint boundary, so cross both mailbox turns.
    barrier()
    barrier()
  end

  defp barrier, do: GenServer.call(Reconciler, :simulation_barrier)

  defp flush_contract_reads do
    receive do
      {:contracts_read, _} -> flush_contract_reads()
    after
      0 -> :ok
    end
  end
end
