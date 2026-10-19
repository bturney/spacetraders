defmodule SpaceTraders.StrategySemanticTimeTest do
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Clock, Evidence, FleetGeneration, FleetStrategy, TestClock}

  @now ~U[2000-01-01 00:00:00.000000Z]

  setup context do
    start_supervised!({TestClock, @now})
    previous = Application.get_env(:spacetraders, :clock)
    Application.put_env(:spacetraders, :clock, TestClock)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:spacetraders, :clock, previous),
        else: Application.delete_env(:spacetraders, :clock)
    end)

    operator = operator_fixture()
    agent = unless context[:mint], do: agent_fixture(operator)
    scope = Scope.for_operator(operator)
    {:ok, draft} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, draft.draft_version)

    %{agent: agent, scope: scope, revision: revision}
  end

  test "Horizon uses semantic freshness and the latest retained acquisition at a frozen instant",
       %{agent: agent} do
    alias SpaceTraders.Evidence.Observation
    alias SpaceTraders.GenerationHorizon

    {:ok, %{generation: generation}} = FleetGeneration.current_fleet()
    facts = %{"response" => %{"serverResets" => %{"next" => "2000-01-01T03:00:00Z"}}}

    older =
      Repo.insert!(%Observation{
        id: "ffffffff-ffff-4fff-bfff-ffffffffffff",
        agent_id: agent.id,
        fleet_generation_id: generation.id,
        subject: "server:status",
        operation_id: "get-status",
        dependency_keys: ["server:status"],
        facts: facts,
        response_fingerprint: Evidence.fingerprint(facts),
        observed_at: @now,
        inserted_at: ~U[2026-01-01 00:00:00.000001Z]
      })

    assert %{status: :known, duration_seconds: 10_800} = GenerationHorizon.current(agent)
    TestClock.advance(31)
    assert %{status: :unknown, reason: :stale_reset_evidence} = GenerationHorizon.current(agent)

    # This later acquisition is malformed. Random UUID order must not resurrect
    # the earlier valid schedule when acquisitions share one semantic instant.
    invalid = %{"response" => %{"serverResets" => %{"next" => "unknown"}}}

    newer =
      Repo.insert!(%{
        older
        | id: "00000000-0000-4000-8000-000000000001",
          facts: invalid,
          response_fingerprint: Evidence.fingerprint(invalid),
          inserted_at: ~U[2026-01-01 00:00:00.000002Z]
      })

    assert Evidence.latest_observation(agent, "server:status").id == newer.id
    assert %{status: :unknown, reason: :invalid_reset_evidence} = GenerationHorizon.current(agent)
  end

  @tag :mint
  test "normal registration establishes semantic Generation chronology", %{
    scope: scope,
    revision: revision
  } do
    {:ok, operator} = SpaceTraders.Agent.link_account_token(scope, "ACCOUNT_TOKEN")
    scope = Scope.for_operator(operator)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      assert conn.request_path == "/v2/register"

      Req.Test.json(conn, %{
        "data" => %{
          "token" => "SEMANTIC_TOKEN",
          "agent" => %{
            "symbol" => "SEMANTIC",
            "credits" => 175_000,
            "headquarters" => "X1-UX81-A1",
            "startingFaction" => "COSMIC"
          },
          "contract" => %{"id" => "c1", "type" => "PROCUREMENT"},
          "faction" => %{"symbol" => "COSMIC"},
          "ships" => [SpaceTraders.ShipBody.ship_body("SEMANTIC-1")]
        }
      })
    end)

    assert {:ok, _} = FleetGeneration.mint(scope, %{symbol: "SEMANTIC", faction: "COSMIC"})
    assert {:ok, %{generation: current}} = FleetGeneration.current_fleet()
    assert current.strategy_capable_at == @now
    assert current.inserted_at == DateTime.truncate(@now, :second)
    assert current.fleet_strategy_revision_id == revision.id
  end

  test "Contract eligibility compares authoritative deadlines with gameplay time" do
    alias SpaceTraders.API.Model.Contract
    alias SpaceTraders.Contracts

    deadline = "2000-01-01T00:00:30Z"
    pending = %Contract{accepted: false, fulfilled: false, deadline_to_accept: deadline}
    accepted = %{pending | accepted: true, terms: %{deadline: deadline}}

    assert Contracts.acceptable?(pending)
    assert Contracts.active?(accepted)
    TestClock.advance(30)
    refute Contracts.expired?(pending)
    TestClock.advance(1)
    assert Contracts.expired?(pending)
    assert Contracts.expired?(accepted)
    refute Contracts.fulfillable?(accepted)
    assert pending.deadline_to_accept == deadline
    assert accepted.terms.deadline == deadline
  end

  test "Generation birth and credit eligibility share semantic time, including expired evidence",
       %{agent: agent, scope: scope, revision: revision} do
    {:ok, %{generation: generation}} = FleetGeneration.current_fleet()
    assert generation.inserted_at == DateTime.truncate(@now, :second)
    assert revision.activated_at == DateTime.truncate(@now, :second)

    generation_fixture(%{generation | starting_credits: 175_000})
    subject = "agent:#{agent.symbol}"

    observation =
      Evidence.authoritative_observation("get-my-agent", [subject], %{
        response: %{credits: 180_000}
      })

    assert {:ok, %{observation: retained}} = Evidence.fulfil_demands(agent, subject, observation)
    assert retained.observed_at == @now
    assert {:ok, %{generation: observed}} = FleetGeneration.current_fleet()
    assert observed.last_observed_credits == 180_000
    assert observed.last_observed_at == @now

    facts = %{
      "change" => 5_000,
      "elapsed_seconds" => 60,
      "horizon_seconds" => 3600,
      "feasible?" => true,
      "evidence_id" => retained.id
    }

    assert {:ok, _} = FleetGeneration.record_objective_progress(scope, generation.id, 0, facts)
    TestClock.advance(301)
    assert Clock.utc_now() == ~U[2000-01-01 00:05:01.000000Z]

    assert {:error, :invalid_objective_progress} =
             FleetGeneration.record_objective_progress(scope, generation.id, 0, facts)

    assert {:ok, %{generation: current}} = FleetGeneration.current_fleet()
    assert current.id == generation.id
    assert current.fleet_strategy_revision_id == revision.id
  end
end
