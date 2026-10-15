defmodule SpaceTraders.GenerationHorizonTest do
  use SpaceTraders.DataCase, async: true

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Evidence
  alias SpaceTraders.GenerationHorizon

  setup do
    %{agent: agent_fixture(operator_fixture())}
  end

  test "a governed public status read retains the exact reset schedule Binding", %{agent: agent} do
    status = %{
      "status" => "online",
      "resetDate" => "2030-01-01",
      "serverResets" => %{"next" => "2030-02-01T00:00:00Z", "frequency" => "monthly"}
    }

    Req.Test.expect(SpaceTraders.API, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v2/"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      Req.Test.json(conn, status)
    end)

    assert {:ok, %Evidence.Binding{value: ^status, observation: source}} =
             Evidence.get_status_binding(agent, owner: "fleet_acquisition", lane: :reconciliation)

    assert source.subject == "server:status"
    assert source.operation_id == "get-status"
    assert source.agent_id == agent.id
    assert {:ok, %{generation: generation}} = SpaceTraders.FleetGeneration.current_fleet()
    assert source.fleet_generation_id == generation.id
    assert source.facts["response"] == status
    assert Evidence.valid_observation?(source)

    assert {:ok, %Evidence.Binding{value: ^status, observation: ^source}} =
             Evidence.retained_binding(agent, source.id)
  end

  test "a distant announced Server Reset bounds the Generation Horizon to the calibrated 48 hours",
       %{agent: agent} do
    next_reset = DateTime.add(DateTime.utc_now(), 10, :day)
    source = acquire_status(agent, next_reset)

    horizon = GenerationHorizon.current(agent, source.observed_at)

    assert horizon.status == :known
    assert horizon.duration_seconds == 172_800
    assert horizon.evidence_ref.observation_id == source.id
    assert horizon.evidence_ref.response_fingerprint == source.response_fingerprint
    assert horizon.evidence_ref.observed_at == source.observed_at

    assert horizon.calibration == %{
             version: "ship-acquisition-v2",
             horizon_window_seconds: 172_800,
             no_history_discount: 0.5
           }
  end

  test "without retained reset evidence the horizon is explicitly unknown", %{agent: agent} do
    assert %{
             status: :unknown,
             duration_seconds: nil,
             evidence_ref: nil,
             reason: :missing_reset_evidence,
             calibration: %{version: "ship-acquisition-v2"}
           } = GenerationHorizon.current(agent)
  end

  test "stale reset evidence yields unknown while preserving the evidence reference", %{
    agent: agent
  } do
    source = acquire_status(agent, DateTime.add(DateTime.utc_now(), 10, :day))

    assert %{status: :unknown, duration_seconds: nil, reason: :stale_reset_evidence} =
             horizon =
             GenerationHorizon.current(agent, DateTime.add(source.observed_at, 31))

    assert horizon.evidence_ref.observation_id == source.id
  end

  test "an announced Server Reset in three hours bounds the horizon to three hours", %{
    agent: agent
  } do
    now = DateTime.add(DateTime.utc_now(), 10)
    source = acquire_status(agent, DateTime.add(now, 3, :hour))

    assert %{status: :known, duration_seconds: 10_800} =
             horizon = GenerationHorizon.current(agent, now)

    assert horizon.evidence_ref.observation_id == source.id
  end

  test "a reached or past reset yields unknown, not zero or a negative duration", %{agent: agent} do
    now = DateTime.add(DateTime.utc_now(), 10)
    source = acquire_status(agent, now)

    for as_of <- [now, DateTime.add(now, 1)] do
      assert %{status: :unknown, duration_seconds: nil, reason: :reset_not_in_future} =
               horizon =
               GenerationHorizon.current(agent, as_of)

      assert horizon.evidence_ref.observation_id == source.id
    end
  end

  test "missing or malformed announced reset time remains unknown with traceable evidence", %{
    agent: agent
  } do
    acquire_status(agent, DateTime.add(DateTime.utc_now(), 10, :day))

    for schedule <- [nil, %{}, %{"next" => nil}, %{"next" => "tomorrow"}, %{"next" => 123}] do
      Req.Test.expect(SpaceTraders.API, fn conn ->
        Req.Test.json(conn, %{"serverResets" => schedule})
      end)

      {:ok, %Evidence.Binding{observation: source}} = Evidence.get_status_binding(agent)

      assert %{status: :unknown, duration_seconds: nil, reason: :invalid_reset_evidence} =
               horizon =
               GenerationHorizon.current(agent, source.observed_at)

      assert horizon.evidence_ref.observation_id == source.id
    end
  end

  test "future-dated evidence is unknown and the standard freshness boundary is exact", %{
    agent: agent
  } do
    source = acquire_status(agent, DateTime.add(DateTime.utc_now(), 10, :day))

    assert %{status: :unknown, duration_seconds: nil, reason: :future_reset_evidence} =
             GenerationHorizon.current(agent, DateTime.add(source.observed_at, -1, :microsecond))

    assert %{status: :known, duration_seconds: 172_800} =
             GenerationHorizon.current(agent, DateTime.add(source.observed_at, 30))

    assert %{status: :unknown, reason: :stale_reset_evidence} =
             GenerationHorizon.current(
               agent,
               DateTime.add(source.observed_at, 30_000_001, :microsecond)
             )
  end

  test "retained evidence for a historical Fleet Generation cannot justify a current investment",
       %{agent: agent} do
    operator = SpaceTraders.Agent.get_operator!(agent.operator_id)
    historical = agent_fixture(operator)
    source = acquire_status(historical, DateTime.add(DateTime.utc_now(), 10, :day))

    assert %{status: :unknown, duration_seconds: nil, reason: :generation_not_current} =
             horizon =
             GenerationHorizon.current(historical, source.observed_at)

    assert horizon.evidence_ref.observation_id == source.id

    assert %{status: :unknown, evidence_ref: nil, reason: :missing_reset_evidence} =
             GenerationHorizon.current(agent)
  end

  test "a different authoritative operation cannot masquerade as reset-schedule evidence", %{
    agent: agent
  } do
    now = DateTime.utc_now()

    observation =
      Evidence.authoritative_observation(
        "get-market",
        ["server:status"],
        %{
          "response" => %{
            "serverResets" => %{"next" => DateTime.to_iso8601(DateTime.add(now, 10, :day))}
          }
        },
        now
      )

    {:ok, %{observation: source}} =
      Evidence.fulfil_demands(agent, "server:status", observation, now)

    assert %{status: :unknown, duration_seconds: nil, reason: :invalid_reset_evidence} =
             horizon =
             GenerationHorizon.current(agent, now)

    assert horizon.evidence_ref.observation_id == source.id
  end

  test "a status Binding fulfils the reset evidence demand with the same retained acquisition", %{
    agent: agent
  } do
    operator = SpaceTraders.Agent.get_operator!(agent.operator_id)
    scope = SpaceTraders.Agent.Scope.for_operator(operator)
    {:ok, strategy} = SpaceTraders.FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = SpaceTraders.FleetStrategy.activate(scope, strategy.draft_version)
    now = DateTime.utc_now()

    {:ok, demand} =
      Evidence.request_demand(agent, revision, %{
        subject: "server:status",
        required_facts: ["response"],
        freshness_seconds: 30,
        due_at: now,
        deadline_at: DateTime.add(now, 60),
        owner: "fleet_acquisition"
      })

    source = acquire_status(agent, DateTime.add(now, 10, :day))
    assert {:ok, fulfilled_source} = Evidence.evidence_for_demand(demand)
    assert fulfilled_source.id == source.id
    assert Evidence.list_open_demands(agent) == []
  end

  defp acquire_status(agent, next_reset) do
    Req.Test.expect(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, %{
        "serverResets" => %{"next" => DateTime.to_iso8601(next_reset), "frequency" => "monthly"}
      })
    end)

    {:ok, %Evidence.Binding{observation: source}} = Evidence.get_status_binding(agent)
    source
  end
end
