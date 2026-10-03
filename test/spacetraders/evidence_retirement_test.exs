defmodule SpaceTraders.EvidenceRetirementTest do
  # Fleet Generation retirement fences the application-wide generation admission cache.
  use SpaceTraders.DataCase, async: false

  import SpaceTraders.AgentFixtures

  alias SpaceTraders.Agent
  alias SpaceTraders.Agent.Scope
  alias SpaceTraders.{Evidence, FleetGeneration, FleetStrategy}

  test "fulfilled Evidence and its Strategy provenance survive Fleet Generation retirement" do
    operator = operator_fixture()
    {:ok, operator} = Agent.link_account_token(operator, "RETIREMENT_ACCOUNT_TOKEN")
    scope = Scope.for_operator(operator)
    {:ok, strategy} = FleetStrategy.select_preset(scope, "steady_growth")
    {:ok, revision} = FleetStrategy.activate(scope, strategy.draft_version)

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body(conn.body_params["symbol"]))
    end)

    assert {:ok, %{agent: first_agent}} =
             FleetGeneration.mint(scope, %{
               symbol: "RETIREDME",
               faction: "COSMIC",
               replacement_symbols: ["RETIREDME", "REPLACED"]
             })

    now = DateTime.utc_now()
    subject = "market:X1-UX81:X1-UX81-A1"

    assert {:ok, demand} =
             Evidence.request_demand(first_agent, revision, %{
               subject: subject,
               required_facts: ["trade_goods"],
               freshness_seconds: 300,
               due_at: DateTime.add(now, -60, :second),
               owner: "fleet_planning"
             })

    observation =
      Evidence.authoritative_observation(
        "get-market",
        [subject],
        %{trade_goods: []},
        now
      )

    assert {:ok, %{demands: [fulfilled], observation: original_evidence}} =
             Evidence.fulfil_demands(first_agent, subject, observation, now)

    assert fulfilled.id == demand.id

    Req.Test.stub(SpaceTraders.API, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{
        "error" => %{
          "code" => 4113,
          "message" =>
            "Failed to parse token. Token reset_date does not match the server. Server resets happen on a weekly to bi-weekly frequency during alpha. After a reset, you should re-register your agent. Expected: 2026-09-15, Actual: 2026-09-01"
        }
      })
    end)

    assert {:error, :stale_agent} = FleetGeneration.agent_overview(Repo.reload!(first_agent))

    Req.Test.stub(SpaceTraders.API, fn conn ->
      Req.Test.json(conn, registration_body(conn.body_params["symbol"]))
    end)

    assert {:ok, _replacement} =
             FleetGeneration.mint(scope, %{
               symbol: "REPLACED",
               faction: "COSMIC",
               replacement_symbols: ["REPLACED"]
             })

    # Retirement nilifies the Agent reference, preserving historical evidence
    # and the fulfilled demand's attribution rather than withdrawing it.
    assert {:ok, retained_evidence} = Evidence.evidence_for_demand(demand)
    assert retained_evidence.id == original_evidence.id
    assert retained_evidence.operation_id == "get-market"
    assert retained_evidence.subject == subject
    assert retained_evidence.agent_id == nil

    retained_demand = Repo.reload!(demand)
    assert retained_demand.fulfilled_observation_id == retained_evidence.id
    assert retained_demand.strategy_revision_id == revision.id
    assert retained_demand.subject == subject
    assert retained_demand.owner == "fleet_planning"
    assert retained_demand.due_at == demand.due_at
    assert retained_demand.withdrawn_at == nil
  end

  defp registration_body(symbol) do
    %{
      "data" => %{
        "token" => "MINTED_TOKEN",
        "agent" => %{
          "symbol" => symbol,
          "credits" => 175_000,
          "headquarters" => "X1-TEST-A1",
          "shipCount" => 2
        },
        "ships" => []
      }
    }
  end
end
