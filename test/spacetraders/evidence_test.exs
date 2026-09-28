defmodule SpaceTraders.EvidenceTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.Evidence
  alias SpaceTraders.Evidence.{Observation, ObservationDemand}
  alias SpaceTraders.FleetStrategy

  test "an Observation Demand preserves its evidence requirement and Strategy provenance" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    due = ~U[2030-01-01 00:30:00.000000Z]
    deadline = ~U[2030-01-01 01:00:00.000000Z]

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "ship:ORBITALIST-1",
               required_facts: ["cargo", "nav"],
               freshness_seconds: 30,
               due_at: due,
               deadline_at: deadline,
               owner: "ship_execution"
             })

    assert demand.agent_id == agent.id
    assert demand.strategy_revision_id == revision.id
    assert demand.subject == "ship:ORBITALIST-1"
    assert demand.required_facts == ["cargo", "nav"]
    assert demand.freshness_seconds == 30
    assert demand.due_at == due
    assert demand.deadline_at == deadline
    assert demand.owner == "ship_execution"
    assert demand.withdrawn_at == nil
    assert demand.fulfilled_observation_id == nil
  end

  test "an Observation Demand rejects Strategy provenance from another Operator" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    other_operator = operator_fixture()
    scope = Scope.for_operator(other_operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    assert {:error, :strategy_provenance_mismatch} =
             Evidence.request_demand(agent, revision, %{
               subject: "ship:ORBITALIST-1",
               required_facts: ["cargo"],
               freshness_seconds: 30,
               due_at: ~U[2030-01-01 00:30:00.000000Z],
               deadline_at: ~U[2030-01-01 01:00:00.000000Z],
               owner: "ship_execution"
             })
  end

  test "one authoritative observation fulfils compatible concurrent demands" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, first} =
      Evidence.request_demand(agent, revision, %{
        subject: "ship:ORBITALIST-1",
        required_facts: ["cargo"],
        freshness_seconds: 30,
        due_at: DateTime.add(now, -60),
        deadline_at: DateTime.add(now, 60),
        owner: "fleet_planning"
      })

    {:ok, second} =
      Evidence.request_demand(agent, revision, %{
        subject: "ship:ORBITALIST-1",
        required_facts: ["cargo", "nav"],
        freshness_seconds: 120,
        due_at: DateTime.add(now, -60),
        deadline_at: DateTime.add(now, 90),
        owner: "ship_execution"
      })

    observation =
      Evidence.authoritative_observation(
        "get-my-ship",
        ["ship:ORBITALIST-1"],
        %{cargo: %{"units" => 10}, nav: %{"status" => "DOCKED"}},
        DateTime.add(now, -10)
      )

    assert {:ok, evidence} =
             Evidence.fulfil_demands(agent, "ship:ORBITALIST-1", observation, now)

    assert MapSet.new(Enum.map(evidence.demands, & &1.id)) == MapSet.new([first.id, second.id])
    assert evidence.observation.operation_id == "get-my-ship"
    assert evidence.observation.agent_id == agent.id
    assert evidence.observation.observed_at == observation.observed_at

    assert evidence.observation.facts == %{
             "cargo" => %{"units" => 10},
             "nav" => %{"status" => "DOCKED"}
           }

    assert evidence.observation.response_fingerprint ==
             Evidence.fingerprint(evidence.observation.facts)

    assert {:ok, returned} = Evidence.evidence_for_demand(first)
    assert returned.id == evidence.observation.id
    assert returned.operation_id == "get-my-ship"
    assert returned.observed_at == observation.observed_at

    assert Repo.aggregate(Observation, :count) == 1

    fulfilled_ids =
      ObservationDemand
      |> Repo.all()
      |> Enum.map(& &1.fulfilled_observation_id)

    assert fulfilled_ids == [evidence.observation.id, evidence.observation.id]
  end

  test "fulfilment fulfils a missed-deadline demand and leaves stale, unrelated, and unknown requirements open" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    demand = fn attrs ->
      Evidence.request_demand(
        agent,
        revision,
        Map.merge(
          %{
            subject: "ship:ORBITALIST-1",
            required_facts: ["cargo"],
            freshness_seconds: 30,
            due_at: DateTime.add(now, -60),
            deadline_at: DateTime.add(now, 60),
            owner: "fleet_planning"
          },
          attrs
        )
      )
    end

    {:ok, compatible} = demand.(%{})
    {:ok, stale} = demand.(%{freshness_seconds: 5})
    {:ok, expired} = demand.(%{deadline_at: DateTime.add(now, -1)})
    {:ok, unrelated} = demand.(%{subject: "ship:ORBITALIST-2"})
    {:ok, unknown} = demand.(%{required_facts: ["cargo", "fuel"]})

    observation =
      Evidence.authoritative_observation(
        "get-my-ship",
        ["ship:ORBITALIST-1"],
        %{cargo: %{"units" => 10}, fuel: nil},
        DateTime.add(now, -10)
      )

    assert {:ok, %{demands: fulfilled, observation: persisted}} =
             Evidence.fulfil_demands(agent, "ship:ORBITALIST-1", observation, now)

    fulfilled_ids = MapSet.new(Enum.map(fulfilled, & &1.id))
    # A missed deadline no longer blocks fulfillment, so the expired demand is
    # fulfilled alongside the compatible one.
    assert MapSet.new([compatible.id, expired.id]) == fulfilled_ids
    assert persisted.facts["fuel"] == nil

    for open <- [stale, unrelated, unknown] do
      assert Repo.get!(ObservationDemand, open.id).fulfilled_observation_id == nil
    end
  end

  test "a demand with an optional deadline is fulfilled by later authoritative evidence" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -30),
        owner: "fleet_planning"
      })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        now
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-A1", observation, now)

    assert fulfilled.id == demand.id
  end

  test "evidence observed after the deadline still fulfils an open demand" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 600,
        due_at: DateTime.add(now, -120),
        deadline_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        now
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-A1", observation, now)

    assert fulfilled.id == demand.id
    # The demand stays durably attributable to its evidence after fulfillment.
    assert %{fulfilled_observation_id: observation_id} = Repo.reload!(demand)
    assert observation_id
  end

  test "evidence observed before a demand's due_at does not fulfil the future demand" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, future_demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, 120),
        owner: "fleet_planning"
      })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        now
      )

    assert {:ok, %{demands: []}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-A1", observation, now)

    # The future demand remains open, unfulfilled, and durably visible.
    assert %{fulfilled_observation_id: nil, withdrawn_at: nil} = Repo.reload!(future_demand)
    assert [open] = Evidence.list_open_demands(agent)
    assert open.id == future_demand.id
  end

  test "consumers can replace and withdraw demands as planning changes" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, original} =
      Evidence.request_demand(agent, revision, %{
        subject: "ship:ORBITALIST-1",
        required_facts: ["cargo"],
        freshness_seconds: 30,
        due_at: now,
        deadline_at: DateTime.add(now, 60),
        owner: "fleet_planning"
      })

    assert {:ok, replacement} =
             Evidence.replace_demand(
               original,
               %{
                 required_facts: ["cargo", "nav"],
                 due_at: DateTime.add(now, 30),
                 deadline_at: DateTime.add(now, 120),
                 agent_id: -1,
                 strategy_revision_id: -1
               },
               now
             )

    assert replacement.replaces_id == original.id
    assert replacement.agent_id == agent.id
    assert replacement.strategy_revision_id == revision.id
    assert replacement.required_facts == ["cargo", "nav"]
    assert replacement.due_at == DateTime.add(now, 30)
    assert Repo.get!(ObservationDemand, original.id).withdrawn_at == now
    assert Enum.map(Evidence.list_open_demands(agent), & &1.id) == [replacement.id]

    assert {:ok, withdrawn} = Evidence.withdraw_demand(replacement, now)
    assert withdrawn.withdrawn_at == now
    assert Evidence.list_open_demands(agent) == []
  end

  test "Market reads declare freshness and persist the returned facts" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, _revision} = FleetStrategy.activate(scope, strategy.draft_version)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/systems/X1-UX81/waypoints/X1-UX81-A1/market"

      Req.Test.json(conn, %{
        "data" => %{
          "symbol" => "X1-UX81-A1",
          "exports" => [%{"symbol" => "IRON_ORE"}],
          "imports" => [],
          "exchange" => []
        }
      })
    end)

    assert {:ok, %{symbol: "X1-UX81-A1"}} =
             Evidence.get_market(agent, "X1-UX81", "X1-UX81-A1",
               owner: "market_planning",
               freshness_seconds: 90
             )

    assert Evidence.list_open_demands(agent) == []
    [observation] = Repo.all(Observation)
    assert observation.subject == "market:X1-UX81:X1-UX81-A1"
    assert observation.operation_id == "get-market"
    assert [%{"symbol" => "IRON_ORE"}] = observation.facts["exports"]
    assert observation.facts["response"]["symbol"] == "X1-UX81-A1"
  end

  test "a future Observation Demand persists its earliest useful due_at while deadline_at stays optional" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    due = ~U[2030-01-01 02:00:00.000000Z]

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: due,
               owner: "fleet_planning"
             })

    assert demand.due_at == due
    assert demand.deadline_at == nil
  end

  test "a missed deadline remains open in demand queries" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -120),
        deadline_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    assert [open] = Evidence.list_open_demands(agent)
    assert open.id == demand.id
    assert DateTime.compare(open.deadline_at, now) == :lt
  end

  test "runtime synchronization creates one open demand per subject and is idempotent" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)
    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    open = Evidence.list_open_demands(agent)
    assert length(open) == 1
    assert hd(open).due_at == DateTime.add(now, 300)
    assert hd(open).owner == "fleet_planning"
  end

  test "synchronization does not extend an already-due demand" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, overdue} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -120),
        owner: "fleet_planning"
      })

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: now,
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    # API backpressure must leave overdue timing unchanged: the open demand
    # keeps its original due instant instead of being pushed forward.
    reloaded = Repo.reload!(overdue)
    assert reloaded.due_at == DateTime.add(now, -120)
    assert reloaded.withdrawn_at == nil
    assert length(Evidence.list_open_demands(agent)) == 1
  end

  test "newer retained evidence replaces an open future demand through provenance" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, original} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, 60),
        owner: "fleet_planning"
      })

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    assert Repo.reload!(original).withdrawn_at
    assert [successor] = Evidence.list_open_demands(agent)
    assert successor.due_at == DateTime.add(now, 300)
    assert successor.replaces_id == original.id
    assert successor.strategy_revision_id == revision.id
  end

  test "a fulfilled demand receives its next successor chained through replaces_id" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        DateTime.add(now, -30)
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-A1", observation, now)

    assert fulfilled.id == demand.id

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 240),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    # The same revision is still active, so its refresh demand continues.
    assert [successor] = Evidence.list_open_demands(agent)
    assert successor.replaces_id == demand.id
    assert successor.due_at == DateTime.add(now, 240)
  end

  test "activating a new Strategy Revision withdraws old-revision demands with provenance" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    agent_id = agent.id
    Phoenix.PubSub.subscribe(SpaceTraders.PubSub, "observation_demands")
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, first_revision} = FleetStrategy.activate(scope, strategy.draft_version)

    {:ok, demand} =
      Evidence.request_demand(agent, first_revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: ~U[2030-01-01 02:00:00.000000Z],
        owner: "fleet_planning"
      })

    active = FleetStrategy.get(scope)

    assert {:ok, _} =
             FleetStrategy.save_draft(
               scope,
               active.active_revision.document,
               active.draft_version
             )

    updated = FleetStrategy.get(scope)
    assert {:ok, second_revision} = FleetStrategy.activate(scope, updated.draft_version)
    assert second_revision.id != first_revision.id

    # The withdrawal notifies the durable scheduler for the actual owning
    # Agent so the earliest due wakeup is reconstructed.
    assert_receive {:observation_demands_changed, ^agent_id}, 1000

    # The live Generation moved to the new revision, so the old revision's
    # open demand loses relevance: withdrawn, never deleted, provenance kept.
    reloaded = Repo.reload!(demand)
    assert reloaded.withdrawn_at
    assert reloaded.strategy_revision_id == first_revision.id
    assert reloaded.subject == "market:X1-UX81:X1-UX81-A1"
    assert reloaded.owner == "fleet_planning"
  end

  test "runtime synchronization keeps owners independently attributable for one subject" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    planner_spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "fleet_planning"
    }

    consumer_spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "ship_execution"
    }

    assert :ok =
             Evidence.sync_runtime_demands(agent, revision, [planner_spec, consumer_spec], now)

    open = Evidence.list_open_demands(agent)
    assert length(open) == 2
    assert Enum.map(open, & &1.owner) |> Enum.sort() == ["fleet_planning", "ship_execution"]

    planner_demand = Enum.find(open, &(&1.owner == "fleet_planning"))
    consumer_demand = Enum.find(open, &(&1.owner == "ship_execution"))

    # Newer evidence moves only the planner's useful time forward: the other
    # consumer's demand is neither replaced nor withdrawn.
    assert :ok =
             Evidence.sync_runtime_demands(
               agent,
               revision,
               [Map.put(planner_spec, :due_at, DateTime.add(now, 600))],
               now
             )

    open = Evidence.list_open_demands(agent)
    assert length(open) == 2

    replaced = Enum.find(open, &(&1.owner == "fleet_planning"))
    untouched = Enum.find(open, &(&1.owner == "ship_execution"))

    assert replaced.due_at == DateTime.add(now, 600)
    assert replaced.replaces_id == planner_demand.id
    assert untouched.id == consumer_demand.id
    assert untouched.due_at == DateTime.add(now, 300)
    assert Repo.reload!(consumer_demand).withdrawn_at == nil
  end

  test "a superseding Revision synchronizes its own demand without chaining to the old Revision" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, first_revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, first_revision, [spec], now)

    active = FleetStrategy.get(scope)

    assert {:ok, _} =
             FleetStrategy.save_draft(
               scope,
               active.active_revision.document,
               active.draft_version
             )

    updated = FleetStrategy.get(scope)
    assert {:ok, second_revision} = FleetStrategy.activate(scope, updated.draft_version)

    assert :ok = Evidence.sync_runtime_demands(agent, second_revision, [spec], now)

    # Activating the superseding Revision already withdrew the old revision's
    # demand; only the new revision's demand remains open.
    open = Evidence.list_open_demands(agent)
    assert [%{strategy_revision_id: new_id, replaces_id: nil}] = open
    assert new_id == second_revision.id

    # Replacement provenance never chains across Revisions: the new demand
    # started fresh, and the old row keeps its own attribution.
    old_revision_demand =
      ObservationDemand
      |> Repo.all()
      |> Enum.find(&(&1.strategy_revision_id == first_revision.id))

    assert old_revision_demand.withdrawn_at
    assert old_revision_demand.replaces_id == nil
    assert old_revision_demand.subject == "market:X1-UX81:X1-UX81-A1"
  end

  test "synchronization reports persistence failures instead of silent success" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    invalid_spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: [],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      owner: "fleet_planning"
    }

    assert {:error, _reason} = Evidence.sync_runtime_demands(agent, revision, [invalid_spec], now)

    # Nothing was durably written, so no wakeup was claimed for nothing.
    assert Evidence.list_open_demands(agent) == []
  end

  test "global scheduling queries ignore demands without an owning Agent" do
    Repo.insert!(%ObservationDemand{
      subject: "market:GHOST:GHOST-1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: ~U[2030-01-01 00:00:00.000000Z],
      owner: "ghost"
    })

    # A historical row with a nilified Agent must never schedule or broadcast.
    assert Evidence.earliest_due_at() == nil
    assert Evidence.due_demands(~U[2031-01-01 00:00:00.000000Z]) == []
  end

  test "a demand rejects a deadline earlier than its earliest useful time" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    assert {:error, changeset} =
             Evidence.request_demand(agent, revision, %{
               subject: "market:X1-UX81:X1-UX81-A1",
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: ~U[2030-01-01 02:00:00.000000Z],
               deadline_at: ~U[2030-01-01 01:00:00.000000Z],
               owner: "fleet_planning"
             })

    assert {:ok, {"cannot precede the earliest useful due_at", _}} =
             Keyword.fetch(changeset.errors, :deadline_at)
  end

  test "synchronization consolidates duplicate open demands for one consumer" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, older} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -120),
        owner: "fleet_planning"
      })

    {:ok, newer} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: now,
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    # Exactly one open demand remains for the consumer: the newest is retained
    # (a due-now description never extends its timing) and the stray is
    # withdrawn with its provenance preserved.
    open = Evidence.list_open_demands(agent)
    assert [%{id: open_id, due_at: open_due}] = open
    assert open_id == newer.id
    assert open_due == DateTime.add(now, -60)
    assert Repo.reload!(older).withdrawn_at
    assert Repo.reload!(older).replaces_id == nil
  end

  test "replacement to a later future due time clears a stale deadline" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, original} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, 60),
        deadline_at: DateTime.add(now, 120),
        owner: "fleet_planning"
      })

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 600),
      deadline_at: nil,
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    assert Repo.reload!(original).withdrawn_at
    assert [successor] = Evidence.list_open_demands(agent)
    assert successor.due_at == DateTime.add(now, 600)
    # The old immediate deadline did not survive the later useful time.
    assert successor.deadline_at == nil
    assert successor.replaces_id == original.id
  end

  test "synchronization carries an explicitly supplied deadline into the created demand" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 300),
      deadline_at: DateTime.add(now, 600),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    assert [demand] = Evidence.list_open_demands(agent)
    assert demand.deadline_at == DateTime.add(now, 600)
    assert demand.due_at == DateTime.add(now, 300)
  end

  test "a description that becomes due now replaces an existing future demand" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, future} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, 300),
        owner: "fleet_planning"
      })

    # The Strategy loses its fresher evidence basis: the refresh is due now.
    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: now,
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    assert Repo.reload!(future).withdrawn_at
    assert [current] = Evidence.list_open_demands(agent)
    assert current.due_at == now
    assert current.replaces_id == future.id
  end

  test "an overdue demand is retained, not extended, when a description moves later" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, overdue} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 300,
        due_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 300,
      due_at: DateTime.add(now, 600),
      owner: "fleet_planning"
    }

    assert :ok = Evidence.sync_runtime_demands(agent, revision, [spec], now)

    # API backpressure protection: the overdue row keeps its timing instead of
    # being silently extended by the newer description.
    assert [open] = Evidence.list_open_demands(agent)
    assert open.id == overdue.id
    assert open.due_at == DateTime.add(now, -60)
    assert open.withdrawn_at == nil
  end

  test "missed deadlines are marked durably while the demand stays open and fulfillable" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "market:X1-UX81:X1-UX81-A1",
        required_facts: ["trade_goods"],
        freshness_seconds: 600,
        due_at: DateTime.add(now, -120),
        deadline_at: DateTime.add(now, -60),
        owner: "fleet_planning"
      })

    assert {:ok, 1} = Evidence.mark_missed_deadlines(now)

    # The demand remains open and visible, now with its durable limitation.
    reloaded = Repo.reload!(demand)
    assert reloaded.deadline_missed_at == now
    assert [%{id: open_id}] = Evidence.list_open_demands(agent)
    assert open_id == demand.id

    # Late authoritative evidence still fulfils it; the marker remains.
    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-A1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        now
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-A1", observation, now)

    assert fulfilled.id == demand.id
    assert Repo.reload!(demand).deadline_missed_at == now
  end

  test "mark_missed_deadlines ignores fulfilled and withdrawn demands" do
    operator = operator_fixture()
    agent = agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)
    now = ~U[2030-01-01 00:00:00.000000Z]

    demand_spec = %{
      subject: "market:X1-UX81:X1-UX81-A1",
      required_facts: ["trade_goods"],
      freshness_seconds: 600,
      due_at: DateTime.add(now, -120),
      deadline_at: DateTime.add(now, -60),
      owner: "fleet_planning"
    }

    {:ok, open_demand} =
      Evidence.request_demand(agent, revision, %{
        demand_spec
        | subject: "market:X1-UX81:X1-UX81-B1"
      })

    {:ok, fulfilled_demand} =
      Evidence.request_demand(agent, revision, %{
        demand_spec
        | subject: "market:X1-UX81:X1-UX81-C1"
      })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["market:X1-UX81:X1-UX81-C1"],
        %{"trade_goods" => %{"state" => "known", "value" => []}},
        now
      )

    assert {:ok, %{demands: [fulfilled]}} =
             Evidence.fulfil_demands(agent, "market:X1-UX81:X1-UX81-C1", observation, now)

    assert fulfilled.id == fulfilled_demand.id

    {:ok, withdrawn_demand} =
      Evidence.request_demand(agent, revision, %{
        demand_spec
        | subject: "market:X1-UX81:X1-UX81-D1"
      })

    assert :ok =
             Evidence.withdraw_market_demands_outside_subjects(
               agent,
               revision,
               ["market:X1-UX81:X1-UX81-B1"],
               now
             )

    # Overdue fulfilled and withdrawn demands stay unmarked; the overdue open
    # demand is marked.
    assert {:ok, 1} = Evidence.mark_missed_deadlines(now)
    assert Repo.reload!(open_demand).deadline_missed_at == now
    refute Repo.reload!(fulfilled_demand).deadline_missed_at
    refute Repo.reload!(withdrawn_demand).deadline_missed_at
  end
end
