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
    deadline = ~U[2030-01-01 01:00:00.000000Z]

    assert {:ok, demand} =
             Evidence.request_demand(agent, revision, %{
               subject: "ship:ORBITALIST-1",
               required_facts: ["cargo", "nav"],
               freshness_seconds: 30,
               deadline_at: deadline,
               owner: "ship_execution"
             })

    assert demand.agent_id == agent.id
    assert demand.strategy_revision_id == revision.id
    assert demand.subject == "ship:ORBITALIST-1"
    assert demand.required_facts == ["cargo", "nav"]
    assert demand.freshness_seconds == 30
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
        deadline_at: DateTime.add(now, 60),
        owner: "fleet_planning"
      })

    {:ok, second} =
      Evidence.request_demand(agent, revision, %{
        subject: "ship:ORBITALIST-1",
        required_facts: ["cargo", "nav"],
        freshness_seconds: 120,
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

  test "fulfilment leaves stale, expired, unrelated, and unknown requirements open" do
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

    assert {:ok, %{demands: [%{id: fulfilled_id}], observation: persisted}} =
             Evidence.fulfil_demands(agent, "ship:ORBITALIST-1", observation, now)

    assert fulfilled_id == compatible.id
    assert persisted.facts["fuel"] == nil

    for open <- [stale, expired, unrelated, unknown] do
      assert Repo.get!(ObservationDemand, open.id).fulfilled_observation_id == nil
    end
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
        deadline_at: DateTime.add(now, 60),
        owner: "fleet_planning"
      })

    assert {:ok, replacement} =
             Evidence.replace_demand(
               original,
               %{
                 required_facts: ["cargo", "nav"],
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
    assert Repo.get!(ObservationDemand, original.id).withdrawn_at == now
    assert Enum.map(Evidence.list_open_demands(agent, now), & &1.id) == [replacement.id]

    assert {:ok, withdrawn} = Evidence.withdraw_demand(replacement, now)
    assert withdrawn.withdrawn_at == now
    assert Evidence.list_open_demands(agent, now) == []
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
end
